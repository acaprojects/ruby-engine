# Usage: rake import:devices_csv['/file/path.csv','test']

# csv filename as argument
# Rows are:
#  Room Type Room Name	Device Name	    Dependency ID	IP Address	   MAC	Serial	        Zone 1	    Zone 2	    Zone 3
#  4p	     17.01	    LG 47" Display	dep_6-00	    10.243.219.24		507KCBD2E085	zone_6-00	zone_6-00	zone_6-00

# Read csv in line by line
#   assume first line is the title
#   check the room name, search existing systems
#		if its new, create the system
#			add the 3 zones listed on the same line
#		if it's existing, return the system that matches
#	Add the device to the system

namespace :import do
    desc 'ACA Engine Device Import tool'
    task(:devices_csv, [:file_name, :run_type] => [:environment]) do |task, args|
        RoomType = 0
        RoomName = 1
        ModuleName = 2
        DepId = 3
        IpAdress = 4
        MacAddress = 5
        Serial = 6
        Zones1 = 7
        Zones2 = 8
        Zones3 = 9


        f = args[:file_name]
        do_save = true
        if args[:run_type] != 'create!'
            do_save = false
        end
		
		systems = {}
		devices = {}
		
        # read line by line
        File.foreach(f).with_index do |line, line_num|
            next if line_num == 0 || line.strip.empty?
            raw = line.strip.split(",")

            # Grab the System Information
            sys_name = "#{raw[RoomName]} - #{raw[RoomType]}"
            system = systems[sys_name]

            if system.nil?
                sys = Orchestrator::ControlSystem.find_by_name sys_name

                unless sys
                    sys = Orchestrator::ControlSystem.new
                    sys.name = sys_name
                    sys.zones = []
                    sys.zones << raw[Zones3] if raw[Zones3] && !raw[Zones3].empty?
                    sys.zones << raw[Zones2] if raw[Zones2] && !raw[Zones2].empty?
                    sys.zones << raw[Zones1] if raw[Zones1] && !raw[Zones1].empty?

                    tries = 0
                    begin
                        sys.save! if do_save
                        puts "Created system #{sys.name}"
                    rescue => e
                        puts "error: #{e.message}"
                        puts sys.errors.messages if sys.errors

                        if tries <= 8
                            sleep 1
                            tries += 1
                            retry
                        else
                            puts "FAILED TO CREATE SYSTEM #{system_name}"
                            raise "FAILED TO CREATE SYSTEM #{system_name}"
                        end
                    end
                end

                system = sys
                systems[sys_name] = sys
            end

            # Create the device
            device = devices[raw[IpAdress]]
            if device.nil?
                # Create the device
                device = Orchestrator::Module.new
                device.dependency_id = raw[DepId]
                device.notes = ''

                if raw[IpAdress] && !raw[IpAdress].empty?
                    device.ip = raw[IpAdress]
                else
                    device.control_system_id = system.id
                end
                
                if raw[MacAddress] && !raw[MacAddress].empty?
                    device.notes = "* MAC: #{raw[MacAddress]}\n"
                    device.settings = {
                        mac_address: raw[MacAddress]
                    }
                end

                if raw[Serial] && !raw[Serial].empty?
                    device.notes = "* Serial: #{raw[Serial]}\n"
                end

                mod_name = raw[ModuleName]

                tries = 0
                begin
                    device.save! if do_save
                    puts "Created device #{mod_name}"
                rescue => e
                    puts "error: #{e.message}"
                    puts device.errors.messages if device.errors

                    if tries <= 8
                        sleep 1
                        tries += 1
                        retry
                    else
                        puts "FAILED TO CREATE DEVICE #{device.ip}"
                        raise "FAILED TO CREATE DEVICE #{device.ip}"
                    end
                end
            end

            system.modules << device.id
		end


        # Complete the system configuration
        systems.each do |name, sys|
            sys.support_url = "https://avcontrol.oc.rabonet.com/meeting/#/?ctrl=#{sys.id}"

            tries = 0
            begin
                sys.save! if do_save
                puts "System Complete #{sys.name}"
            rescue => e
                puts "error: #{e.message}"
                puts sys.errors.messages if sys.errors

                if tries <= 8
                    sleep 1
                    tries += 1
                    retry
                else
                    puts "FAILED TO CREATE SYSTEM #{system_name}"
                    raise "FAILED TO CREATE SYSTEM #{system_name}"
                end
            end
        end
	end
end
