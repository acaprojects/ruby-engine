# frozen_string_literal: true

class ModuleGenerator < Rails::Generators::NamedBase
    #source_root File.expand_path('../templates', __FILE__)
    
    def create_module_file
        
        name = file_name.downcase.gsub(/\s|-/, '_')
        param = class_path
        param.map! {|item| item.downcase.gsub(/\s|-/, '_')}
        
        path = File.join('app/modules', *param)
        
        scope = []
        text = String.new
        param.map! {|item|
            item = item.camelcase
            scope << item
            text += "module #{scope.join('::')}; end\n"
            item
        }
        param << name.camelcase
        scope = param.join('::')
        
        
        create_file File.join(path, "#{name}.rb") do            
            text += <<-FILE


class #{scope}
    include ::Orchestrator::Constants  # On, Off and other useful constants
    include ::Orchestrator::Transcoder # binary, hex and string helper methods
    # For stream tokenization use ::UV::BufferedTokenizer or ::UV::AbstractTokenizer

    def on_load
        # module has been started
    end
    
    def on_unload
        # module has been stopped
    end
    
    # Called when class updated at runtime
    def on_update
    end
end

            FILE
            
            text
        end
        
    end
end
