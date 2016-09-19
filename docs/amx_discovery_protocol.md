# AMX Discovery Protocol


* Multicast address 239.255.250.250
* UDP port 9131

Device will broadcast messages that look like:

```ruby

"AMXB <-SDKClass=VideoProjector> <-UUID=DEADBEEF> <-Make=Epson> <-Model=EB-4950WU>\r"
# OR
"AMXB<-UUID=001122334455><-SDKClass=AudioConferencer><-Make=Polycom>
<-Model=SoundStructureC16><-Revision=1.0.0><Config-Name=SoundStructure C16
Configuration> <Config-URL=http://172.22.2.109/>\r"

```

## Common Field Names

* Device-SDKClass
* -SDKClass
* Device-UUID
* -UUID 
* Device-Make
* -Make
* Device-Model
* -Model
* Device-Revision
* -Revision
* Bundle-Version


## Class Names

* Amplifier
* AudioProcessor
* DigitalMediaServer
* DiscDevice
* HVAC
* LightSystem
* PoolSpa
* SecuritySystem
* VideoProcessor
* VolumeController
* AudioConferencer
* AudioTunerDevice
* DigitalSatelliteSystem
* DocumentCamera
* Keypad
* Monitor
* PreAmpSurroundSoundProcessor
* SensorDevice
* Switcher
* VideoProjector
* Weather
* AudioMixer
* Camera
* DigitalVideoRecorder
* Light
* Motor
* Receiver
* SettopBox
* TV
* VideoConferencer
* VideoWall


## Example Code

```ruby

# ------------------
# Server (listening)
# ------------------
require 'libuv'

reactor do |reactor|
    reactor.udp { |data, ip, port|
        puts "received #{data.chomp} from #{ip}:#{port}"
    }
    .bind('0.0.0.0', 9131)
    .join('239.255.250.250', '0.0.0.0')
    .start_read
end


# --------------
# Example Client
# --------------
require 'libuv'

reactor do |reactor|
    reactor.udp
    .bind('0.0.0.0', 0)
    .enable_broadcast
    .send('239.255.250.250', 9131, "AMXB <-SDKClass=VideoProjector> <-UUID=DEADBEEF> <-Make=Epson> <-Model=EB-4950WU>\r")
end

```

