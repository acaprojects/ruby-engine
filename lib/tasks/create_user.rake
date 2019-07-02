namespace :user do
    # Usage: rake user:create domain=string email=string name=string password=string admin=true
    desc 'Create a user in a given domain'
    task(:create => :environment) do |task|
        begin
            authority = ::Authority.find_by_domain ENV['domain']
        rescue => e
            puts "#{e.message}\n#{e.backtrace.join("\n")}"
        else
            begin
                user = User.new
                user.name = ENV['name']
                user.sys_admin = ENV['admin'].downcase == 'true'
                user.authority_id = authority.id
                user.email = ENV['email']
                user.password = user.password_confirmation = ENV['password']
                user.save!
                puts "User created!\n#{ENV['domain']}: #{ENV['name']} (#{ENV['email']}:#{ENV['password']}) = #{user.id}"
            rescue => e
                puts "User creation failed with:"
                if e.respond_to?(:record)
                    puts e.record.errors.messages
                else
                    puts "#{e.message}\n#{e.backtrace.join("\n")}"
                end
            end
        end
    end
end