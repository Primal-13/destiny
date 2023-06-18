WITH
linked_bungies AS
(
  SELECT
        bungie_platform_data.account AS account,
        bungie_platform_data.platform AS platform,
        bungie_platform_data.value AS membership_id
  FROM `levelcrush_accounts`.account_platforms  AS account_platforms
  INNER JOIN `levelcrush_accounts`.`account_platform_data` AS bungie_platform_data ON
        account_platforms.account = bungie_platform_data.account  AND
        account_platforms.id  = bungie_platform_data.platform AND
        bungie_platform_data.key = 'primary_membership_id'
  WHERE account_platforms.platform = 'bungie'
),
linked_discords AS
(
    SELECT
        linked_bungies.account,
        discord_platform_data.platform,
        linked_bungies.membership_id,
        discord_platform_data.value AS discord_display_name
    FROM linked_bungies
    INNER JOIN `levelcrush_accounts`.account_platforms AS discord_platform ON
        linked_bungies.account = discord_platform.account AND
        discord_platform.platform = 'discord'
    INNER JOIN `levelcrush_accounts`.account_platform_data AS discord_platform_data ON
        discord_platform.account = discord_platform_data.account AND
        discord_platform.id = discord_platform_data.platform  AND
        discord_platform_data.key = 'display_name'
),
target_members AS (
    SELECT
        members.*
    FROM clans
    INNER JOIN clan_members ON clans.group_id = clan_members.group_id
    INNER JOIN members ON clan_members.membership_id = members.membership_id
    WHERE clans.is_network = 1
),
target_activities AS
(
   SELECT
       member_activities.instance_id,
       member_activities.membership_id
   FROM target_members
   INNER JOIN member_activities ON target_members.membership_id = member_activities.membership_id
   WHERE member_activities.mode = 4 # raids
   GROUP BY member_activities.instance_id, member_activities.membership_id
),
target_activities_with_durations AS
(
    SELECT
        target_activities.instance_id,
        target_activities.membership_id,
        MAX(member_activity_stats.value) AS activityDurationSeconds
    FROM target_activities
    INNER JOIN member_activity_stats ON
           target_activities.instance_id = member_activity_stats.instance_id AND
           target_activities.membership_id = member_activity_stats.membership_id  AND
           member_activity_stats.name = 'activityDurationSeconds'
    GROUP BY target_activities.instance_id, target_activities.membership_id
),
full_clear_activities AS
(
    SELECT
        instances.instance_id,
        target_activities_with_durations.membership_id
    FROM target_activities_with_durations
    INNER JOIN instances ON target_activities_with_durations.instance_id = instances.instance_id
    INNER JOIN instance_members ON
        target_activities_with_durations.membership_id = instance_members.membership_id AND
        target_activities_with_durations.instance_id = instance_members.instance_id
    #WHERE instance_members.completed = 1
    WHERE instances.completed = 1
    AND (
        # any activity before beyond light **may** have a starting phase index set. In our system if they came in with a starting phase index or not does not matter
        # we default to 0 if there is none present. So starting phase index = 0 equals the start of an activity (the beginning)
        # unless there is somewhere in the documentation that says otherwise (this is an assumption, could not find any additional info in documentation)
        (instances.occurred_at <= 1605045600 AND instances.starting_phase_index = 0) OR
        # any instance that occurred after beyond light, will not have a starting phase index. So it is effectively 0 always no point in including it
        # any activity between now and witch queen release **should** not have a starting_from_beginnning field populated so that will equal 0.
        # this is according to bungie documentation.
        (instances.occurred_at >= 1605045600 AND instances.occurred_at <= 1645567200) OR
        (instances.occurred_at >= 1645567200 AND instances.started_from_beginning = 1)
    )
    AND target_activities_with_durations.activityDurationSeconds > 600 # only accept if they are longer then 10 minutes long
    GROUP BY instances.instance_id, target_activities_with_durations.membership_id
),

leaderboard AS (
    SELECT
        COALESCE(linked_discords.discord_display_name,
        target_members.display_name_global)        AS display_name,
        COUNT(DISTINCT full_clear_activities.instance_id) AS amount
    FROM target_members
    LEFT JOIN full_clear_activities ON target_members.membership_id = full_clear_activities.membership_id
    LEFT JOIN linked_bungies ON target_members.membership_id = linked_bungies.membership_id
    LEFT JOIN linked_discords ON linked_bungies.account = linked_discords.account
    GROUP BY target_members.display_name_global, target_members.membership_id, linked_discords.discord_display_name
),
leaderboard_standings AS (
    SELECT
        leaderboard.display_name,
        leaderboard.amount,
        (CUME_DIST() OVER w)  * 100 AS `distance`,
        (PERCENT_RANK() OVER w) * 100 AS `ranking`
    FROM leaderboard
    WINDOW w AS (ORDER BY leaderboard.amount DESC)
)

SELECT
    *
FROM leaderboard_standings