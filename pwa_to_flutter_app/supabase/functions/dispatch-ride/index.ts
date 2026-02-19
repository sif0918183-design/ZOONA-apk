import { serve } from "https://deno.land/std@0.168.0/http/server.ts"
import { createClient } from "https://esm.sh/@supabase/supabase-js@2"

const corsHeaders = {
  'Access-Control-Allow-Origin': '*',
  'Access-Control-Allow-Headers': 'authorization, x-client-info, apikey, content-type',
}

serve(async (req) => {
  // Handle CORS
  if (req.method === 'OPTIONS') {
    return new Response('ok', { headers: corsHeaders })
  }

  try {
    const supabaseClient = createClient(
      Deno.env.get('SUPABASE_URL') ?? '',
      Deno.env.get('SUPABASE_SERVICE_ROLE_KEY') ?? ''
    )

    const { ride_id, pickup_lat, pickup_lng, vehicle_type, amount, distance, pickup_address, destination_address } = await req.json()

    console.log(`🚀 Dispatching ride ${ride_id} for vehicle type ${vehicle_type}`);

    // 1. Find nearest online drivers using a PostGIS query
    // We assume an RPC 'get_nearest_drivers' exists or we use a raw SQL approach via a custom function
    const { data: drivers, error: driversError } = await supabaseClient.rpc('get_nearest_drivers_v2', {
      lat: pickup_lat,
      lng: pickup_lng,
      v_type: vehicle_type,
      max_dist: 10000, // 10km
      max_drivers: 3 // Limited to 3 to stay within Edge Function 60s timeout
    })

    if (driversError) {
      console.error('❌ Error fetching drivers:', driversError)
      throw driversError
    }

    if (!drivers || drivers.length === 0) {
      console.log('⚠️ No drivers found')
      return new Response(JSON.stringify({ message: 'No drivers available' }), {
        headers: { ...corsHeaders, 'Content-Type': 'application/json' },
        status: 200,
      })
    }

    console.log(`Found ${drivers.length} potential drivers. Starting sequential notification...`);

    // 2. Sequential notification loop
    for (const driver of drivers) {
      // Check if the ride is still available (hasn't been cancelled or already accepted)
      const { data: ride } = await supabaseClient
        .from('rides')
        .select('status')
        .eq('id', ride_id)
        .single()

      if (!ride || ride.status !== 'searching') {
        console.log(`Ride ${ride_id} is no longer searching. Status: ${ride?.status}`);
        break
      }

      console.log(`🔔 Notifying driver ${driver.driver_id}...`);

      // Create a ride request record for this driver
      // This will trigger the Realtime listener in the Flutter app
      const { error: insertError } = await supabaseClient
        .from('ride_requests')
        .insert({
          ride_id: ride_id,
          driver_id: driver.driver_id,
          payload: {
            ride_id,
            pickup_lat,
            pickup_lng,
            vehicle_type,
            amount,
            distance,
            pickup_address,
            destination_address,
            customer_name: 'Passenger', // Should come from request
            timestamp: new Date().toISOString()
          }
        })

      if (insertError) {
        console.error(`❌ Error notifying driver ${driver.driver_id}:`, insertError)
        continue
      }

      // Wait for 15 seconds for the driver to accept
      // In a real production environment, we might use a more robust state machine or
      // check periodically if the ride status changed.
      const waitTime = 15000; // 15 seconds
      await new Promise(resolve => setTimeout(resolve, waitTime));

      // Check if THIS driver accepted the ride
      const { data: acceptedRequest } = await supabaseClient
        .from('ride_requests')
        .select('status')
        .eq('ride_id', ride_id)
        .eq('driver_id', driver.driver_id)
        .eq('status', 'accepted')
        .maybeSingle()

      if (acceptedRequest) {
        console.log(`✅ Ride ${ride_id} accepted by driver ${driver.driver_id}`);
        break
      }

      console.log(`⏰ Timeout for driver ${driver.driver_id}. Moving to next...`);
    }

    return new Response(JSON.stringify({ success: true }), {
      headers: { ...corsHeaders, 'Content-Type': 'application/json' },
      status: 200,
    })

  } catch (error) {
    console.error('❌ Server error:', error)
    return new Response(JSON.stringify({ error: error.message }), {
      headers: { ...corsHeaders, 'Content-Type': 'application/json' },
      status: 400,
    })
  }
})
