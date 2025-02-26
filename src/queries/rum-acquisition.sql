--- description: Get page views by acquisition source for a given URL for a specified time period.
--- Authorization: none
--- Access-Control-Allow-Origin: *
--- interval: 30
--- offset: 0
--- startdate: 2020-01-01
--- enddate: 2020-12-31
--- granularity: 1
--- traffic_source: -
--- acquisition_type: -
--- url: -
--- timezone: UTC
--- domainkey: secret

-- Lars wrote - We have two distinct categories:
-- Organic vs. Paid: this is based on the utm-campagin checkpoint
-- Search vs. Social vs. Direct vs. Email vs. Display: this is based on the enter checkpoint
-- I think traffic_source = search | social | display | email | direct and acquisition_type = paid | organic should be separate fields in the result

WITH daily_events AS (
  SELECT
    id,
    hostname,
    checkpoint,
    source,
    target,
    weight,
    -- date is used for event correlation
    TIMESTAMP_TRUNC(time, HOUR, @timezone) AS date,
    -- dategroup is used for response in the desired granularity
    TIMESTAMP_TRUNC(time, DAY, @timezone) AS dategroup
  FROM
    helix_rum.EVENTS_V5(
      @url, # url
      CAST(@offset AS INT64), # offset
      CAST(@interval AS INT64), # days to fetch
      @startdate, # start date
      @enddate, # end date
      @timezone, # timezone
      'all', # deviceclass
      @domainkey # domain key to prevent data sharing
    )
  WHERE
    checkpoint IN ('enter', 'top', 'utm')
    AND user_agent NOT IN ('bot', 'undefined')
),

weekly_events AS (
  SELECT
    id,
    hostname,
    checkpoint,
    source,
    target,
    weight,
    TIMESTAMP_TRUNC(time, HOUR, @timezone) AS date,
    TIMESTAMP_TRUNC(time, ISOWEEK, @timezone) AS dategroup
  FROM
    helix_rum.EVENTS_V5(
      @url, # url
      CAST(@offset AS INT64), # offset
      CAST(@interval AS INT64), # days to fetch
      @startdate, # start date
      @enddate, # end date
      @timezone, # timezone
      'all', # deviceclass
      @domainkey # domain key to prevent data sharing
    )
  WHERE
    checkpoint IN ('enter', 'top', 'utm')
    AND user_agent NOT IN ('bot', 'undefined')
),

monthly_events AS (
  SELECT
    id,
    hostname,
    checkpoint,
    source,
    target,
    weight,
    TIMESTAMP_TRUNC(time, HOUR, @timezone) AS date,
    TIMESTAMP_TRUNC(time, MONTH, @timezone) AS dategroup
  FROM
    helix_rum.EVENTS_V5(
      @url, # url
      CAST(@offset AS INT64), # offset
      CAST(@interval AS INT64), # days to fetch
      @startdate, # start date
      @enddate, # end date
      @timezone, # timezone
      'all', # deviceclass
      @domainkey # domain key to prevent data sharing
    )
  WHERE
    checkpoint IN ('enter', 'top', 'utm')
    AND user_agent NOT IN ('bot', 'undefined')
),

events AS (
  SELECT
    id,
    date,
    dategroup,
    hostname,
    checkpoint,
    source,
    target,
    weight
  FROM daily_events
  WHERE CAST(@granularity AS INT64) = 1
  UNION ALL
  SELECT
    id,
    date,
    dategroup,
    hostname,
    checkpoint,
    source,
    target,
    weight
  FROM weekly_events
  WHERE CAST(@granularity AS INT64) = 7
  UNION ALL
  SELECT
    id,
    date,
    dategroup,
    hostname,
    checkpoint,
    source,
    target,
    weight
  FROM monthly_events
  WHERE CAST(@granularity AS INT64) = 30
),

enter_events AS (
  SELECT
    id,
    date,
    dategroup,
    hostname,
    checkpoint,
    source,
    weight
  FROM events
  WHERE
    checkpoint = 'enter'
    AND target = 'visible'
),

top_events AS (
  SELECT
    id,
    date,
    dategroup,
    hostname,
    checkpoint,
    source,
    weight
  FROM events
  WHERE
    checkpoint = 'top'
),

top_events_without_enter AS (
  SELECT
    t.id,
    t.date,
    t.dategroup,
    t.hostname,
    t.checkpoint,
    t.source,
    t.weight
  FROM top_events AS t
  LEFT JOIN enter_events AS e ON t.id = e.id AND t.date = e.date
  WHERE e.id IS NULL
),

utm_source_events AS (
  SELECT
    id,
    date,
    dategroup,
    hostname,
    checkpoint,
    source,
    target,
    weight
  FROM events
  WHERE
    checkpoint = 'utm'
    AND source = 'utm_source'
),

utm_medium_events AS (
  SELECT
    id,
    date,
    dategroup,
    hostname,
    checkpoint,
    source,
    target,
    weight
  FROM events
  WHERE
    checkpoint = 'utm'
    AND source = 'utm_medium'
),

utm_campaign_events AS (
  SELECT
    id,
    date,
    dategroup,
    hostname,
    checkpoint,
    source,
    target,
    weight
  FROM events
  WHERE
    checkpoint = 'utm'
    AND source = 'utm_campaign'
),

utm_content_events AS (
  SELECT
    id,
    date,
    dategroup,
    hostname,
    checkpoint,
    source,
    target,
    weight
  FROM events
  WHERE
    checkpoint = 'utm'
    AND source = 'utm_content'
),

utm_paid_events AS (
  SELECT
    id,
    date,
    dategroup,
    hostname,
    checkpoint,
    source,
    weight
  FROM utm_medium_events
  -- not all utm events are paid, filter further
  WHERE (
    LOWER(target) LIKE '%paid%'
    OR LOWER(target) LIKE 'cp%'
    OR LOWER(target) LIKE 'pp%'
  )
),

events_with_utm AS (
  SELECT
    e.id,
    e.dategroup,
    e.hostname,
    e.checkpoint,
    e.source,
    e.weight,
    ANY_VALUE(us.target) AS utm_source,
    ANY_VALUE(um.target) AS utm_medium,
    ANY_VALUE(uc.target) AS utm_campaign,
    ANY_VALUE(uc2.target) AS utm_content,
    IF(COUNT(up.source) = 0, 'organic', 'paid') AS acquisition_type
  FROM enter_events AS e
  LEFT JOIN utm_source_events AS us ON e.id = us.id AND e.date = us.date
  LEFT JOIN utm_medium_events AS um ON e.id = um.id AND e.date = um.date
  LEFT JOIN utm_campaign_events AS uc ON e.id = uc.id AND e.date = uc.date
  LEFT JOIN utm_content_events AS uc2 ON e.id = uc2.id AND e.date = uc2.date
  LEFT JOIN utm_paid_events AS up ON e.id = up.id AND e.date = up.date
  GROUP BY e.id, e.dategroup, e.hostname, e.checkpoint, e.source, e.weight
  UNION ALL
  SELECT
    id,
    dategroup,
    hostname,
    checkpoint,
    '' AS source,
    weight,
    NULL AS utm_source,
    NULL AS utm_medium,
    NULL AS utm_campaign,
    NULL AS utm_content,
    'organic' AS acquisition_type
  FROM top_events_without_enter
),

events_grouped AS (
  SELECT
    dategroup AS date,
    hostname,
    checkpoint,
    source,
    weight,
    utm_source,
    utm_medium,
    utm_campaign,
    utm_content,
    acquisition_type,
    COUNT(source) AS count
  FROM events_with_utm
  GROUP BY
    dategroup,
    hostname,
    checkpoint,
    source,
    weight,
    utm_source,
    utm_medium,
    utm_campaign,
    utm_content,
    acquisition_type
),

events_channels AS (
  SELECT
    acquisition_type,
    STRING(date, @timezone) AS date,
    COALESCE(
      -- segmentation is based on first match so the sequence of matching logic is important
      IF(checkpoint = 'top', 'internal', NULL),
      -- display
      IF(utm_medium = 'display', 'display', NULL),
      IF(utm_source = 'dbm', 'display', NULL),
      IF(utm_source = 'dcm', 'display', NULL),
      IF(utm_medium = 'dfa', 'display', NULL),
      -- search
      IF(source LIKE '%google%', 'search', NULL),
      IF(source LIKE '%duckduckgo%', 'search', NULL),
      IF(source LIKE '%yahoo%', 'search', NULL),
      IF(source LIKE '%bing%', 'search', NULL),
      IF(source LIKE '%ecosia%', 'search', NULL),
      IF(source LIKE '%baidu%', 'search', NULL),
      IF(source LIKE '%search%', 'search', NULL),
      IF(source LIKE '%yandex%', 'search', NULL),
      -- social
      IF(source LIKE '%facebook%', 'social', NULL),
      IF(source LIKE '%messenger%', 'social', NULL),
      IF(source LIKE '%reddit%', 'social', NULL),
      IF(source LIKE '%justanswer%', 'social', NULL),
      IF(source LIKE '%pinterest%', 'social', NULL),
      IF(source LIKE '%linkedin%', 'social', NULL),
      IF(source LIKE '%tiktok%', 'social', NULL),
      IF(source LIKE '%buzzfeed%', 'social', NULL),
      IF(source LIKE '%youtube%', 'social', NULL),
      -- email
      IF(utm_medium = 'email', 'email', NULL),
      IF(source LIKE '%mail%', 'email', NULL),
      -- referral
      -- affiliate
      IF(utm_medium = 'affiliate', 'affiliate', NULL),
      IF(utm_campaign = 'affiliate', 'affiliate', NULL),
      -- direct
      IF(source = '', 'direct', NULL),
      -- everything else
      'unassigned'
    ) AS traffic_source,
    SUM(weight * count) AS pageviews
  FROM events_grouped
  GROUP BY
    date,
    checkpoint,
    source,
    utm_source,
    utm_medium,
    utm_campaign,
    acquisition_type
)

SELECT
  date,
  traffic_source,
  acquisition_type,
  SUM(pageviews) AS pageviews
FROM events_channels
WHERE
  (@traffic_source = '-' OR @traffic_source = traffic_source)
  AND (@acquisition_type = '-' OR @acquisition_type = acquisition_type)
GROUP BY date, traffic_source, acquisition_type
ORDER BY acquisition_type, traffic_source, date
--- date: date (or start date for date periods) of the reported metric
--- traffic_source: categorization of where users are coming from
--- acquisition_type: organic or paid
--- pageviews: estimated page views for the given traffic source / acquisition type combination
