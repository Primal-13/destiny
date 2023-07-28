use crate::database::platform::AccountPlatform;
use levelcrush::database;
use levelcrush::macros::{DatabaseRecord, DatabaseResult};
use levelcrush::util::unix_timestamp;
use levelcrush::{project_str, tracing, types::RecordId};
use sqlx::SqlitePool;
use std::collections::HashMap;

#[DatabaseRecord]
pub struct AccountPlatformData {
    pub account: RecordId,
    pub platform: RecordId,
    pub key: String,
    pub value: String,
}

#[DatabaseResult]
struct AccountPlatformDataSlim {
    pub id: RecordId,
    pub key: String,
}

#[DatabaseResult]
pub struct NewAccountPlatformData {
    pub key: String,
    pub value: String,
}

pub async fn read(account_platform: &AccountPlatform, keys: &[&str], pool: &SqlitePool) -> HashMap<String, RecordId> {
    let mut results = HashMap::new();

    //sqlx/mysql does not allow us to pass an vector into a prepared statement, so we must manually construct a prepared statement and bind manually
    let mut in_parameters = Vec::new();
    for key in keys.iter() {
        in_parameters.push("?");
        results.insert(key.to_string(), 0);
    }

    // insert the prepared parameters into the query string now
    let in_parameters = in_parameters.join(",");
    //let query = format!(project_str!("queries/account_platform_data_read.sql"), in_parameters);
    let query = project_str!("queries/account_platform_data_read.sql", in_parameters);

    // start constructing the query
    let mut query_builder = sqlx::query_as::<_, AccountPlatformDataSlim>(query.as_str())
        .bind(account_platform.account)
        .bind(account_platform.id);

    for key in keys.iter() {
        query_builder = query_builder.bind(key);
    }

    // execute the query
    let query_result = query_builder.fetch_all(pool).await;
    if query_result.is_ok() {
        let query_result = query_result.unwrap_or_default();
        for record in query_result.iter() {
            results
                .entry(record.key.clone())
                .and_modify(|record_id| *record_id = record.id);
        }
    } else {
        let err = query_result.err().unwrap();
        tracing::error!("Read Platform Data Error: {}", err);
    }
    results
}

pub async fn write(account_platform: &AccountPlatform, values: &[NewAccountPlatformData], pool: &SqlitePool) {
    // get all keys we need to work with and at the same time construct a hash map that represents the key/value pairs we want to link
    let mut keys = Vec::new();
    let mut value_map = HashMap::new();
    let mut query_parameters = Vec::new();
    for (index, new_data) in values.iter().enumerate() {
        keys.push(new_data.key.as_str());
        value_map.insert(new_data.key.clone(), index);

        query_parameters.push("(?,?,?,?,?,?,?,?)");
    }

    //  pull in the existing data related to the specified account platform. We will use this to merge and figure out which are new or need to be updated
    let existing_data = read(account_platform, &keys, pool).await;
    let query_parameters = query_parameters.join(", ");
    let insert_statement = format!(
        project_str!("queries/account_platform_data_insert.sql"),
        query_parameters
    );

    let mut query_builder = sqlx::query(insert_statement.as_str());

    // construct a hash map of all new values that need to be inserted
    for (key, record_id) in existing_data.iter() {
        let data_index = value_map.get(key).unwrap();
        let record = values.get(*data_index).unwrap();

        // make sure to produce a 255 length version of the string if neccessary
        let mut value_trimmed = String::new();
        if record.value.len() > 255 {
            value_trimmed = record.value.clone().get(0..255).unwrap_or_default().to_string();
        } else {
            value_trimmed = record.value.clone();
        }

        if *record_id == 0 {
            // new record for sure bind parameters to match
            query_builder = query_builder
                .bind(0)
                .bind(account_platform.account)
                .bind(account_platform.id)
                .bind(record.key.clone())
                .bind(record.value.clone())
                .bind(unix_timestamp())
                .bind(0)
                .bind(0);
        } else {
            query_builder = query_builder
                .bind(record_id)
                .bind(account_platform.account)
                .bind(account_platform.id)
                .bind(record.key.clone())
                .bind(record.value.clone())
                .bind(0) // our query wont actually pull from the from this if its a duplicate key (which this path is for)
                .bind(unix_timestamp())
                .bind(0);
        }
    }

    // finally execute the query to update/insert this data
    let query = query_builder.execute(pool).await;
    database::log_error(query);
}
