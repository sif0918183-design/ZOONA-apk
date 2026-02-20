-- Enable PostGIS extension if not already enabled
CREATE EXTENSION IF NOT EXISTS postgis;

-- Function to find nearest drivers
CREATE OR REPLACE FUNCTION get_nearest_drivers_v2(
  lat DOUBLE PRECISION,
  lng DOUBLE PRECISION,
  v_type TEXT,
  max_dist INT DEFAULT 10000,
  max_drivers INT DEFAULT 5
)
RETURNS TABLE (
  driver_id UUID,
  distance DOUBLE PRECISION,
  vehicle_type TEXT
)
LANGUAGE plpgsql
SECURITY DEFINER
AS $$
BEGIN
  RETURN QUERY
  SELECT
    dl.driver_id,
    ST_Distance(
      dl.location,
      ST_SetSRID(ST_MakePoint(lng, lat), 4326)::geography
    ) AS distance,
    d.vehicle_type
  FROM
    driver_locations dl
  JOIN
    drivers d ON d.id = dl.driver_id
  WHERE
    dl.is_online = true
    AND d.vehicle_type = v_type
    AND dl.last_seen > now() - interval '5 minutes'
    AND ST_DWithin(
      dl.location,
      ST_SetSRID(ST_MakePoint(lng, lat), 4326)::geography,
      max_dist
    )
  ORDER BY
    distance ASC
  LIMIT
    max_drivers;
END;
$$;
