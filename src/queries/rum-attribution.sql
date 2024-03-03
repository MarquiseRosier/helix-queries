--- description: Which sources and targets for a given checkpoint have the highest conversion rates within a given attribution window?
--- Authorization: none
--- Access-Control-Allow-Origin: *
--- url: -
--- limit: 100
--- offset: 0
--- startdate: 2020-01-01
--- enddate: 2021-01-01
--- timezone: UTC
--- conversioncheckpoint: click
--- sources: -
--- targets: -
--- checkpoint: viewmedia
--- within: 10
--- attribute: target
--- domainkey: secret

WITH alldata AS (
  SELECT
    id,
    checkpoint,
    source,
    target,
    lcp
  FROM
    `helix-225321.helix_rum.EVENTS_V3`(
      @url,
      -1,
      -1,
      @startdate,
      @enddate,
      @timezone,
      "all",
      @domainkey
    )
),

all_checkpoints AS (
  SELECT * FROM
    helix_rum.CHECKPOINTS_V3(
      @url, # domain or URL
      -1, # offset in days from today
      -1, # interval in days to consider
      @startdate, # not used, start date
      @enddate, # not used, end date
      @timezone, # timezone
      "all", # device class
      @domainkey
    )
),

source_target_converted_checkpoints AS (
  SELECT
    all_checkpoints.id AS id,
    ANY_VALUE(source) AS source,
    ANY_VALUE(target) AS target,
    ANY_VALUE(all_checkpoints.pageviews) AS pageviews
  FROM all_checkpoints
  WHERE
    all_checkpoints.checkpoint = @conversioncheckpoint
    AND EXISTS (
      SELECT 1
      FROM
        UNNEST(SPLIT(@sources, ",")) AS prefix
      WHERE all_checkpoints.source LIKE CONCAT(TRIM(prefix), "%")
    )
    AND EXISTS (
      SELECT 1
      FROM
        UNNEST(SPLIT(@targets, ",")) AS prefix
      WHERE all_checkpoints.target LIKE CONCAT(TRIM(prefix), "%")
    )
  GROUP BY all_checkpoints.id
),

source_converted_checkpoints AS (
  SELECT
    all_checkpoints.id AS id,
    ANY_VALUE(source) AS source,
    ANY_VALUE(target) AS target,
    ANY_VALUE(pageviews) AS pageviews
  FROM all_checkpoints
  WHERE
    all_checkpoints.checkpoint = @conversioncheckpoint
    AND EXISTS (
      SELECT 1
      FROM
        UNNEST(SPLIT(@sources, ",")) AS prefix
      WHERE all_checkpoints.source LIKE CONCAT(TRIM(prefix), "%")
    )
  GROUP BY all_checkpoints.id
),

target_converted_checkpoints AS (
  SELECT
    all_checkpoints.id AS id,
    ANY_VALUE(source) AS source,
    ANY_VALUE(target) AS target,
    ANY_VALUE(pageviews) AS pageviews
  FROM all_checkpoints
  WHERE
    all_checkpoints.checkpoint = @conversioncheckpoint
    AND EXISTS (
      SELECT 1
      FROM
        UNNEST(SPLIT(@targets, ",")) AS prefix
      WHERE all_checkpoints.target LIKE CONCAT(TRIM(prefix), "%")
    )
  GROUP BY all_checkpoints.id
),

loose_converted_checkpoints AS (
  SELECT
    all_checkpoints.id AS id,
    ANY_VALUE(source) AS source,
    ANY_VALUE(target) AS target,
    ANY_VALUE(pageviews) AS pageviews
  FROM all_checkpoints
  WHERE all_checkpoints.checkpoint = @conversioncheckpoint
  GROUP BY all_checkpoints.id
),

converted_checkpoints AS (
  SELECT * FROM loose_converted_checkpoints
  WHERE @sources = "-" AND @targets = "-"
  UNION ALL
  SELECT * FROM source_target_converted_checkpoints
  WHERE @sources != "-" AND @targets != "-"
  UNION ALL
  SELECT * FROM source_converted_checkpoints
  WHERE @sources != "-" AND @targets = "-"
  UNION ALL
  SELECT * FROM target_converted_checkpoints
  WHERE @sources = "-" AND @targets != "-"
),

all_attributable_checkpoints AS (
  SELECT
    id,
    checkpoint,
    source,
    target,
    IF(@attribute = "target", target, source) AS attributable
    time, -- noqa
  FROM alldata
  WHERE checkpoint = @checkpoint
),

attributable_sessions AS (
  SELECT
    all_attributable_checkpoints.id,
    all_attributable_checkpoints.attributable,
    all_attributable_checkpoints.time AS time_of_action,
    converted_checkpoints.time AS time_of_conversion,
    IF(
      converted_checkpoints.id IS NULL,
      FALSE,
      TIMESTAMP_DIFF(
        all_attributable_checkpoints.time,
        converted_checkpoints.time,
        SECOND
      ) <= @within
    ) AS converted
  FROM all_attributable_checkpoints LEFT JOIN converted_checkpoints
    ON all_attributable_checkpoints.id = converted_checkpoints.id
),

attribution AS (
  SELECT
    attributable,
    COUNT(DISTINCT id) AS sessions,
    COUNTIF(converted) AS conversions,
    SAFE_DIVIDE(COUNTIF(DISTINCT id), COUNT(DISTINCT id)) AS conversion_rate,
    AVG(time_of_conversion - time_of_action) AS mean_time_to_conversion,
    # row number for each attributable, so that we can paginate
    ROW_NUMBER() OVER (ORDER BY COUNTIF(converted) DESC) AS result_position
  FROM attributable_sessions
  GROUP BY attributable
)

# hlx:metadata
SELECT COUNT(*) AS total_rows
FROM attribution;


SELECT
  attributable,
  sessions,
  conversions,
  conversion_rate,
  mean_time_to_conversion
FROM attribution
ORDER BY conversions DESC
WHERE -- noqa
  result_position > CAST(@offset AS INT64) 
  AND result_position <= CAST(@offset AS INT64) + CAST(@limit AS INT64);
--- attributable: the source or target to attribute the conversion to
--- sessions: the total number of sessions that had the action of interest
--- conversions: the number of sessions that had the action of interest and converted
--- conversion_rate: the number of conversions divided by the number of sessions
--- mean_time_to_conversion: the average time to conversion for sessions that converted
