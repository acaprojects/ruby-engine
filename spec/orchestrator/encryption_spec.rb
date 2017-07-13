require 'rails'
require 'orchestrator'
require 'securerandom'
require 'orchestrator/encryption'
require File.expand_path("../helpers", __FILE__)

describe Orchestrator::Subscription do
    before :each do
        ::Rails.application = Struct.new(:secrets).new
        ::Rails.application.secrets = Struct.new(:secret_key_base).new
        ::Rails.application.secrets.secret_key_base = SecureRandom.hex
        @log = []
    end

    it "should encrypt and decrypt data using secret key as the password" do
        clear_text  = "No one should know this password"

        # Keys are used as additional security
        # Can't move an encrypted value to a new location
        id  = 'mod-id'
        key = 'db-key'
        cipher_text = ::Orchestrator::Encryption.encode_setting(id, key, clear_text)

        # Indicator that content is encoded
        expect(cipher_text[0]).to eq("\e")

        decrypted = ::Orchestrator::Encryption.decode_setting(id, key, cipher_text)
        expect(decrypted).to eq(clear_text)
    end
end
