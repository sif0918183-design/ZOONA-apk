-- Enable RLS for rides and ride_requests if not already enabled
ALTER TABLE public.rides ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.ride_requests ENABLE ROW LEVEL SECURITY;

-- Allow drivers to update ride status to 'accepted'
-- This assumes drivers are authenticated or we use a secret key/anon key with proper filtering
DROP POLICY IF EXISTS "Allow drivers to accept rides" ON public.rides;
CREATE POLICY "Allow drivers to accept rides" ON public.rides
FOR UPDATE
TO anon, authenticated
USING (status = 'pending')
WITH CHECK (status = 'accepted');

-- Allow drivers to update their ride_requests status
DROP POLICY IF EXISTS "Allow drivers to update their ride requests" ON public.ride_requests;
CREATE POLICY "Allow drivers to update their ride requests" ON public.ride_requests
FOR UPDATE
TO anon, authenticated
USING (true)
WITH CHECK (status = 'accepted');

-- Note: In a production environment, you should replace 'TO anon, authenticated'
-- with more restrictive roles or check the driver_id against the user's metadata.
