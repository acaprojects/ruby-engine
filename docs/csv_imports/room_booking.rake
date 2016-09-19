# NOTE:: ONLY FOR USE WITH THE 2016 JLT Melb project
# -- UPDATE ZONES for future imports

# USAGE: rake import:jlt_melb['/file/path.csv','test']
# csv file to be formatted like:
#   room_name,room_number,cmr,email,capacity


PANEL_LOGIC_ID = 'dep_1-10'
ZONES = ["zone_1-16", "zone_1-11"]

namespace :import do

    desc 'System Import tool for JLT Melb project'
    task(:jlt_melb, [:file_name, :run_type] => [:environment]) do |task, args|

        f = args[:file_name]
        func = args[:run_type]

        # We store the AddSys struct instances in here
        systems = []


        AddSys = Struct.new(
            :room_name, :room_number, :email, :capacity, :cmr, :cmr_num
        ) do
            def system_name
                "Melbourne - #{self.room_name} (#{self.room_number})"
            end
            
            def support_url(sys_id)
                "http://au-rbs-1/booking-panel/#/?ctrl=#{sys_id}"
            end
            
            def create!
                sys = Orchestrator::ControlSystem.find_by_name system_name

                # Only create new systems if they don't exist already (might have needed IDs early)
                unless sys
                    sys = Orchestrator::ControlSystem.new
                    sys.name = system_name
                    sys.zones = ZONES
                    sys.bookable = true
                    sys.installed_ui_devices = 1
                    sys.email = self.email
                    sys.capacity = self.capacity
                    sys.settings = {
                        "touch_enabled" => true,
                        "room_timezone" => "Melbourne",
                        "room_name" => "#{self.room_number} - #{self.room_name}",
                        "meetings" => {
                            "dial_in_text" => {
                                "room_number" => self.cmr_num
                            },
                            "detect_using" => "Cloud Meeting Room #{self.cmr_num}",
                            "timezone" => "Melbourne",
                            "cmr_id" => self.cmr
                        }
                    }
                end


                # Deal with the database (just in case it doesn't want to play ball)
                tries = 0
                begin
                    sys.save!
                rescue => e
                    puts "error: #{e.message} -- #{sys.errors.messages}"

                    if tries <= 8
                        sleep 1
                        tries += 1
                        retry
                    else
                        puts "FAILED TO CREATE SYSTEM #{system_name}"
                        return
                    end
                end
                
                if sys.modules.length == 0
                    dev = Orchestrator::Module.new
                    dev.dependency_id     = PANEL_LOGIC_ID
                    dev.control_system_id = sys.id
                    dev.notes = system_name

                    tries = 0
                    begin
                        dev.save!
                    rescue => e
                        puts "error: #{e.message} -- #{dev.errors.messages}"

                        if tries <= 8
                            sleep 1
                            tries += 1
                            retry
                        else
                            puts "FAILED TO CREATE LOGIC IN SYSTEM #{system_name}"
                            return
                        end
                    end
                    
                    sys.support_url = support_url(sys.id)
                    sys.modules = [dev.id]

                    tries = 0
                    begin
                        sys.save!
                    rescue => e
                        puts "error: #{e.message} -- #{sys.errors.messages}"

                        if tries <= 8
                            sleep 1
                            tries += 1
                            retry
                        else
                            puts "FAILED TO UPDATE SYSTEM #{system_name}"
                            return
                        end
                    end
                end

                puts "Finished creating #{system_name}"
            end
            
            def test
                sys = Orchestrator::ControlSystem.find_by_name system_name

                # Only create new systems if they don't exist already (might have needed IDs)
                unless sys
                    puts "NEW Building: #{system_name}"
                    sys = Orchestrator::ControlSystem.new
                    sys.name = system_name
                    sys.zones = ZONES
                    sys.bookable = true
                    sys.installed_ui_devices = 1
                    sys.email = self.email
                    sys.capacity = self.capacity
                    sys.settings = {
                        "touch_enabled" => true,
                        "room_timezone" => "Melbourne",
                        "room_name" => "#{self.room_number} - #{self.room_name}",
                        "meetings" => {
                            "dial_in_text" => {
                                "room_number" => self.cmr_num
                            },
                            "detect_using" => "Cloud Meeting Room #{self.cmr_num}",
                            "timezone" => "Melbourne",
                            "cmr_id" => self.cmr
                        }
                    }

                    puts "details: #{sys}"
                else
                    # We output like this so that after the import is complete
                    # we can run test again for a CSV of system IDs
                    puts "#{system_name},#{sys.id}"
                end


                if sys.modules.length == 0
                    puts "would create logic"

                    dev = Orchestrator::Module.new
                    dev.dependency_id     = PANEL_LOGIC_ID
                    dev.control_system_id = sys.id
                    dev.notes = system_name
                end

                sys.support_url = support_url('temp-id')
            end
        end

        # read line by line
        File.foreach(f).with_index do |line, line_num|

            # skip if line is empty
            next if line.strip.empty?

            raw = line.split(",")
            
            # Fill out our storage object
            system = AddSys.new
            system.room_name = raw[0]
            system.room_number = raw[1]
            system.cmr = raw[2]
            system.cmr_num = system.cmr[3..-1]
            system.email = raw[3]
            system.capacity = raw[4]
            
            systems << system
        end

        # Check if we are testing or going for it
        if func != 'create!'
            func = :test
            puts "System Name,System ID"
        else
            func = :create!
        end
        systems.each {|sys| sys.send(func)}
    end
end
