# frozen_string_literal: true
#
# RLPX
require 'ethruby/key'
require 'digest/sha3'
require_relative 'secrets'

module ETH
  module DevP2P
    module RLPX

      SHA_LENGTH = 32
      SIGNATURE_LENGTH = 65
      PUBLIC_KEY_LENGTH = 64
      ECIES_OVERHEAD = 65 + 16 + 32
      AUTH_MSG_LENGTH = SIGNATURE_LENGTH + SHA_LENGTH + PUBLIC_KEY_LENGTH + SHA_LENGTH + 1
      AUTH_RESP_MSG_LENGTH = PUBLIC_KEY_LENGTH + SHA_LENGTH + 1

      HANDSHAKE_TIMEOUT = 5

      ENC_AUTH_MSG_LENGTH = AUTH_MSG_LENGTH + ECIES_OVERHEAD
      ENC_AUTH_RESP_MSG_LENGTH = AUTH_RESP_MSG_LENGTH + ECIES_OVERHEAD

      # handle key exchange handshake
      class EncryptionHandshake
        attr_reader :private_key, :remote_key, :remote_random_key, :initiator_nonce, :receiver_nonce, :remote_id

        def initialize(private_key:, remote_id:)
          @private_key = private_key
          @remote_id = remote_id
        end

        def remote_key
          @remote_key || @remote_id.key
        end

        def random_key
          @random_key ||= ETH::Key.random
        end

        def auth_msg
          # make nonce bytes
          nonce = random_nonce(SHA_LENGTH)
          @initiator_nonce = nonce
          # remote first byte tag
          token = dh_compute_key(private_key, remote_key)
          raise StandardError.new("token size #{token.size} not correct") if token.size != nonce.size
          # xor
          signed = xor(token, nonce)

          signature = random_key.ecdsa_signature(signed)
          initiator_pubkey = private_key.raw_public_key[1..-1]
          AuthMsgV4.new(signature: signature, initiator_pubkey: initiator_pubkey, nonce: nonce, version: 4)
        end

        def handle_auth_msg(msg)
          @remote_key = ETH::Key.new(raw_public_key: "\x04" + msg.initiator_pubkey)
          @initiator_nonce = msg.nonce

          token = dh_compute_key(private_key, @remote_key)
          signed = xor(token, msg.nonce)
          @remote_random_key = ETH::Key.ecdsa_recover(signed, msg.signature)
        end

        def auth_ack_msg
          # make nonce bytes
          nonce = random_nonce(SHA_LENGTH)
          @receiver_nonce = nonce
          random_pubkey = random_key.raw_public_key[1..-1]
          AuthRespV4.new(random_pubkey: random_pubkey, nonce: nonce, version: 4)
        end

        def handle_auth_ack_msg(msg)
          # make nonce bytes
          @receiver_nonce = msg.nonce
          @remote_random_key = ETH::Key.new(raw_public_key: "\x04" + msg.random_pubkey)
        end

        def extract_secrets(auth_packet, auth_ack_packet, initiator:)
          secret = dh_compute_key(random_key, remote_random_key)
          shared_secret = ETH::Utils.sha3(secret, ETH::Utils.sha3(receiver_nonce, initiator_nonce))
          aes_secret = ETH::Utils.sha3(secret, shared_secret)
          mac = ETH::Utils.sha3(secret, aes_secret)
          secrets = Secrets.new(remote_id: remote_id, aes: aes_secret, mac: mac)

          # initial secrets macs
          mac1 = Digest::SHA3.new(256)
          mac1.update xor(mac, receiver_nonce)
          mac1.update auth_packet

          mac2 = Digest::SHA3.new(256)
          mac2.update xor(mac, initiator_nonce)
          mac2.update auth_ack_packet

          if initiator
            secrets.egress_mac = mac1
            secrets.ingress_mac = mac2
          else
            secrets.egress_mac = mac2
            secrets.ingress_mac = mac1
          end
          secrets
        end

        private

        def dh_compute_key(private_key, public_key)
          private_key.ec_key.dh_compute_key(public_key.ec_key.public_key)
        end

        def xor(b1, b2)
          b1.each_byte.with_index.map {|b, i| b ^ b2[i].ord}.pack('c*')
        end

        def random_nonce(size)
          size.times.map {rand(8)}.pack('c*')
        end

      end
    end
  end
end