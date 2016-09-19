# frozen_string_literal: true

require 'rails'
require 'orchestrator'

describe "command queue" do
    before :each do
        @reactor = ::Libuv::Reactor.default
        @log = []
        @queue = ::Orchestrator::Device::CommandQueue.new(@reactor)
        @dequeue = proc { |cmd|
            @queue.waiting = nil
            @log << (cmd[:meta] || cmd[:name])
        }
    end

    it "should be able to enque and dequeue regular commands" do
        @reactor.run do
            @queue.push({meta: :first}, 50)
            @queue.pop(@dequeue)
        end

        expect(@log).to eq([:first])
    end

    it "should not matter about order" do
        @reactor.run do
            @queue.pop(@dequeue)
            @queue.push({meta: :first}, 50)
        end

        expect(@log).to eq([:first])
    end

    it "should be able to enque and dequeue named commands" do
        @reactor.run do
            @queue.push({name: :first}, 50)
            @queue.pop(@dequeue)
        end

        expect(@log).to eq([:first])
    end

    it "should enque commands in order" do
        @reactor.run do
            @queue.push({name: :first}, 100)
            @queue.push({meta: :second}, 50)
            @queue.push({name: :third}, 60)
            @queue.push({meta: :fourth}, 50)
            
            @queue.pop(@dequeue)
            @reactor.next_tick do
                @queue.pop(@dequeue)
                @reactor.next_tick do
                    @queue.pop(@dequeue)
                    @reactor.next_tick do
                        @queue.pop(@dequeue)
                    end
                end
            end
        end

        expect(@log).to eq([:first, :third, :second, :fourth])
    end

    it "should track named commands" do
        @reactor.run do
            @queue.push({meta: :first, name: :bob, defer: @reactor.defer}, 60)
            @queue.push({meta: :second}, 50)
            @queue.push({meta: :third}, 100)
            @queue.push({meta: :fourth, name: :bob, defer: @reactor.defer}, 50)
            
            @queue.pop(@dequeue)
            @reactor.next_tick do
                @queue.pop(@dequeue)
                @reactor.next_tick do
                    @queue.pop(@dequeue)
                end
            end
        end

        expect(@log).to eq([:third, :fourth, :second])
    end

    it "should be able to clear the queue" do
        @reactor.run do
            @queue.push({meta: :first, name: :bob, defer: @reactor.defer}, 60)
            @queue.push({meta: :second, defer: @reactor.defer}, 50)
            @queue.push({meta: :third, defer: @reactor.defer}, 100)
            @queue.push({meta: :fourth, name: :bob, defer: @reactor.defer}, 50)
            
            @queue.pop(@dequeue)
            @reactor.next_tick do
                @queue.cancel_all 'module requested'
            end
        end

        expect(@log).to eq([:third])
        expect(@queue.length).to eq(0)
    end

    it "should only save named commands when offline" do
        @reactor.run do
            @queue.push({meta: :first, name: :bob, defer: @reactor.defer}, 60)
            @queue.push({meta: :second, defer: @reactor.defer}, 50)
            @queue.push({meta: :third, defer: @reactor.defer}, 100)
            @queue.push({meta: :fourth, name: :bob, defer: @reactor.defer}, 50)

            @queue.offline
            begin
                expect(@queue.length).to eq(1)
            rescue
            end
            
            @queue.pop(@dequeue)
        end

        expect(@log).to eq([:fourth])
    end

    it "should not save any commands if offline and commands are to be cleared" do
        @reactor.run do
            @queue.push({meta: :first, name: :bob, defer: @reactor.defer}, 60)
            @queue.push({meta: :second, defer: @reactor.defer}, 50)
            @queue.push({meta: :third, defer: @reactor.defer}, 100)
            @queue.push({meta: :fourth, name: :bob, defer: @reactor.defer}, 50)

            @queue.offline(:clear)
            begin
                expect(@queue.length).to eq(0)
            rescue
            ensure
                @reactor.stop
            end
        end
    end

    it "should only accept named commands when offline" do
        @reactor.run do
            @queue.offline(:clear)

            @queue.push({meta: :first, name: :bob, defer: @reactor.defer}, 60)
            @queue.push({meta: :second, defer: @reactor.defer}, 50)
            @queue.push({meta: :third, defer: @reactor.defer}, 100)
            @queue.push({meta: :fourth, name: :bob, defer: @reactor.defer}, 50)
            @queue.push({meta: :fith, name: :jane, defer: @reactor.defer}, 50)

            begin
                expect(@queue.length).to eq(2)
            rescue
            end
            
            @queue.pop(@dequeue)
        end

        expect(@log).to eq([:fourth])
    end

    it "should only accept a single pop every tick" do
        # i.e. if pop is called twice the last callback provided
        # will be the only callback called in the next tick
        # the previous callback provided will be discarded

        @reactor.run do
            @queue.push({meta: :first, name: :bob, defer: @reactor.defer}, 60)
            @queue.push({meta: :second, defer: @reactor.defer}, 50)
            @queue.push({meta: :third, defer: @reactor.defer}, 100)
            @queue.push({meta: :fourth, name: :bob, defer: @reactor.defer}, 50)
            @queue.push({meta: :fith, name: :jane, defer: @reactor.defer}, 50)

            
            @queue.pop(proc { @log << :error1 })
            @queue.pop(proc { @log << :error2 })
            @queue.pop(@dequeue)
        end

        expect(@log).to eq([:third])
    end

    it "won't perform a pop if the callback is cleared" do
        @reactor.run do
            @queue.push({meta: :first, name: :bob, defer: @reactor.defer}, 60)
            @queue.push({meta: :second, defer: @reactor.defer}, 50)
            
            @queue.pop @dequeue
            @queue.pop nil

            @reactor.next_tick do
                begin
                    expect(@queue.length).to eq(2)
                rescue
                end
                @reactor.stop
            end
        end

        expect(@log).to eq([])
    end
end
