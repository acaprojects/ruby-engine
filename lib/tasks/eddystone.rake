# frozen_string_literal: true, encoding: ASCII-8BIT

namespace :eddystone do

EDDYSTONE_TEMPLATE = <<-EDDYSTONE
<!doctype html>
<html>
  <head>
    <meta charset="utf-8">
    <meta http-equiv="X-UA-Compatible" content="IE=edge,chrome=1">
    <title>${system_name}</title>
    <meta name="description" content="take control of this space">
    <link rel="icon" type="image/png" href="48.png" sizes="48x48">
    <link rel="icon" type="image/png" href="64.png" sizes="64x64">
    <link rel="icon" type="image/png" href="128.png" sizes="128x128">
    <link rel="icon" type="image/png" href="192.png" sizes="192x192">
    <meta name="mobile-web-app-capable" content="yes">
    <meta name="apple-mobile-web-app-capable" content="yes">
    <meta name="format-detection" content="telephone=no" />
    <meta name="apple-mobile-web-app-status-bar-style" content="black-translucent">
  </head>
  <body>
    Please wait while your interface loads...
    <script>
      setTimeout(function () {
          location.href = '${system_url}';
      }, 3000);
    </script>
  </body>
</html>
EDDYSTONE

    # Usage: rake eddystone:build['zone_1-10','a','../eddystone','https://control.path/ui/#/?ctrl=${system_id}','https://aca.im/pwc/${eddystone_id}']

    desc 'Generates eddystone compatible pages for accessing control systems'
    task :build, [:zone_id, :start, :directory, :url_template, :eddystone_template] => [:environment] do |task, args|
        # Ensure directory exists
        require 'fileutils'
        dir = File.expand_path(args[:directory], Rails.root)
        FileUtils.mkdir_p dir

        # Encode the system count
        b10 = Radix::Base.new(10)
        start = Radix.convert(args[:start], Radix::BASE::B62, b10).to_i

        zone_id = args[:zone_id]
        puts "Building files in #{dir}\nfor zone #{zone_id} with id starting at #{start}:\n"

        # Generate a summary file
        File.open(File.expand_path("summary_#{zone_id}.csv", dir), 'w') do |summary|
            summary.write("eddystone URI,system name,system id")

            # Build the template
            url_template = args[:url_template]
            eddystone_template = args[:eddystone_template]
            ::Orchestrator::ControlSystem.in_zone(args[:zone_id]).each do |system|
                start += 1

                system_name = system.settings[:room_name] || system.name
                system_id = system.id
                file_name = Radix.convert(start, b10, Radix::BASE::B62)

                url = url_template.gsub('${system_id}', system_id)
                file_content = EDDYSTONE_TEMPLATE.gsub('${system_name}', system_name).gsub('${system_url}', url)
                File.write(File.expand_path(file_name, dir), file_content)

                eddystone_url = eddystone_template.gsub('${eddystone_id}', file_name)
                puts " - wrote '#{file_name}'\t#{system_id}: #{system_name}"
                summary.write "\n#{eddystone_url},#{system_name},#{system_id}"
            end
        end
    end

end
