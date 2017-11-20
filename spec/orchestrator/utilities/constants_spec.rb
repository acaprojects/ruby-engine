# frozen_string_literal: true

require 'rails'
require 'orchestrator'

describe 'module constants mixin' do

    # NOTE:: If all tests pass then we've also tested __reset_config
    #  implicitly as the config state isn't persisted between tests

    before :each do
        class TestModule
            include ::Orchestrator::Constants
        end
        @inst = TestModule.new
    end

    it 'should add config helpers to classes that include it' do
        expect(TestModule.respond_to?(:tokenize)).to eq(true)
    end

    it 'should return empty config if none is defined' do
        config = TestModule.__default_config(@inst)
        req_opts = TestModule.__default_opts(@inst)

        expect(config).to be_a(Hash)
        expect(req_opts).to be_a(Hash)

        expect(config.empty?).to eq(true)
        expect(req_opts.empty?).to eq(true)
    end

    # Tests: delay, wait_response, clear_queue_on_disconnect!, 
    #  flush_buffer_on_disconnect!, queue_priority, before_transmit, tokenize

    it 'should support the delay helper' do
        class TestModule
            delay between_sends: 150
            delay on_receive: 300
        end

        config = TestModule.__default_config(@inst)
        req_opts = TestModule.__default_opts(@inst)

        expect(config.empty?).to eq(true)
        expect(req_opts).to eq({
            delay: 150,
            delay_on_receive: 300
        })
    end

    it 'should support the wait_response helper' do
        class TestModule
            wait_response timeout: 6000, retries: 3
            wait_response false
        end

        config = TestModule.__default_config(@inst)
        req_opts = TestModule.__default_opts(@inst)

        expect(config.empty?).to eq(true)
        expect(req_opts).to eq({
            timeout: 6000,
            retries: 3,
            wait: false
        })
    end

    it 'should support the bang helpers' do
        class TestModule
            clear_queue_on_disconnect!
            flush_buffer_on_disconnect!
        end

        config = TestModule.__default_config(@inst)
        req_opts = TestModule.__default_opts(@inst)

        expect(req_opts.empty?).to eq(true)
        expect(config).to eq({
            clear_queue_on_disconnect: true,
            flush_buffer_on_disconnect: true
        })
    end

    it 'should support the queue_priority helper' do
        class TestModule
            queue_priority default: 50, bonus: 20
        end

        config = TestModule.__default_config(@inst)
        req_opts = TestModule.__default_opts(@inst)

        expect(req_opts).to eq({
            priority: 50
        })
        expect(config).to eq({
            priority_bonus: 20
        })
    end

    it 'should support a single before_transmit callback' do
        class TestModule
            before_transmit :cb

            def cb(data)
                data
            end
        end

        config = TestModule.__default_config(@inst)
        req_opts = TestModule.__default_opts(@inst)

        expect(req_opts.empty?).to eq(true)
        expect(config[:before_transmit].call('check')).to eq('check')
    end

    it 'should support a multiple before_transmit callbacks' do
        class TestModule
            SOME_PROC = proc {|data| "#{data}3"}

            before_transmit :cb, :cb2
            before_transmit SOME_PROC

            def cb(data)
                "#{data}1"
            end
            
            def cb2(data)
                "#{data}2"
            end
        end

        config = TestModule.__default_config(@inst)
        req_opts = TestModule.__default_opts(@inst)

        expect(req_opts.empty?).to eq(true)
        expect(config[:before_transmit].respond_to?(:call)).to eq(true)
        expect(config[:before_transmit].call("testing")).to eq("testing123")
    end

    it 'should support defining a tokeniser' do
        class TestModule
            tokenise delimiter: "\r"
        end

        config = TestModule.__default_config(@inst)
        req_opts = TestModule.__default_opts(@inst)

        expect(req_opts.empty?).to eq(true)
        expect(config).to eq({
            tokenize: true,
            delimiter: "\r"
        })
    end

    it 'should support abstract tokenisers' do
        class TestModule
            tokenize indicator: "\r", callback: :cb, wait_ready: "login:"

            def cb(data)
                3
            end
        end

        config = TestModule.__default_config(@inst)
        req_opts = TestModule.__default_opts(@inst)

        expect(req_opts.empty?).to eq(true)

        expect(config[:wait_ready]).to eq("login:")
        expect(config[:tokenize]).to be_a(Proc)

        tokeniser = config[:tokenize].call
        expect(tokeniser).to be_a(::UV::AbstractTokenizer)
        expect(tokeniser.callback.call(1)).to be(3)
    end

    it 'should throw an error if the tokeniser config does not meet requirements' do
        expect {
            class TestModule
                tokenise indicator: "\r"
            end
        }.to raise_error(ArgumentError)
    end


    it 'should support defining an inactivity timeout' do
        class TestModule
            inactivity_timeout 3000
        end

        config = TestModule.__default_config(@inst)
        req_opts = TestModule.__default_opts(@inst)

        expect(req_opts.empty?).to eq(true)
        expect(config).to eq({
            inactivity_timeout: 3000
        })
    end


    it 'should support defining HTTP keepalive' do
        class TestModule
            keepalive false
        end

        config = TestModule.__default_config(@inst)
        req_opts = TestModule.__default_opts(@inst)

        expect(config.empty?).to eq(true)
        expect(req_opts).to eq({
            keepalive: false
        })
    end
end
