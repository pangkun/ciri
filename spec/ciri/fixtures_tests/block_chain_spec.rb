# frozen_string_literal: true

# Copyright 2018 Jiang Jinyang <https://justjjy.com>
#
# Licensed under the Apache License, Version 2.0 (the "License");
# you may not use this file except in compliance with the License.
# You may obtain a copy of the License at
#
#     http://www.apache.org/licenses/LICENSE-2.0
#
# Unless required by applicable law or agreed to in writing, software
# distributed under the License is distributed on an "AS IS" BASIS,
# WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
# See the License for the specific language governing permissions and
# limitations under the License.


require 'spec_helper'
require 'ciri/core_ext'
require 'ciri/pow_chain/chain'
require 'ciri/evm'
require 'ciri/state'
require 'ciri/types/account'
require 'ciri/forks/frontier'
require 'ciri/utils'
require 'ciri/db/backend/memory'
require 'ciri/key'

using Ciri::CoreExt

RSpec.describe Ciri::POWChain::Chain do

  before(:all) do
    prepare_ethereum_fixtures
  end

  def parse_account(account_hash)
    storage = account_hash["storage"].map do |k, v|
      [k.decode_hex, v.decode_hex.pad_zero(32)]
    end.to_h
    account = Ciri::Types::Account.new(
        balance: account_hash["balance"].decode_hex.decode_big_endian,
        nonce: account_hash["nonce"].decode_hex.decode_big_endian)
    code = account_hash['code'].decode_hex
    [account, code, storage]
  end

  def parse_header(data)
    columns = {}
    columns[:logs_bloom] = data['bloom'].decode_hex
    columns[:beneficiary] = data['coinbase'].decode_hex
    columns[:difficulty] = data['difficulty'].decode_hex.decode_big_endian
    columns[:extra_data] = data['extraData'].decode_hex
    columns[:gas_limit] = data['gasLimit'].decode_hex.decode_big_endian
    columns[:gas_used] = data['gasUsed'].decode_hex.decode_big_endian
    columns[:mix_hash] = data['mixHash'].decode_hex
    columns[:nonce] = data['nonce'].decode_hex
    columns[:number] = data['number'].decode_hex.decode_big_endian
    columns[:parent_hash] = data['parentHash'].decode_hex
    columns[:receipts_root] = data['receiptTrie'].decode_hex
    columns[:state_root] = data['stateRoot'].decode_hex
    columns[:transactions_root] = data['transactionsTrie'].decode_hex
    columns[:timestamp] = data['timestamp'].decode_hex.decode_big_endian
    columns[:ommers_hash] = data['uncleHash'].decode_hex

    header = Ciri::POWChain::Header.new(**columns)
    unless Ciri::Utils.to_hex(header.get_hash) == data['hash']
      p columns
    end
    header
  end

  def extract_fork_config(fixture)
    network = fixture['network']
    schema_rules = case network
                   when "Frontier"
                     [
                         [0, Ciri::Forks::Frontier::Schema.new],
                     ]
                   when "Homestead"
                     [
                         [0, Ciri::Forks::Homestead::Schema.new(support_dao_fork: false)],
                     ]
                   when "EIP150"
                     [
                         [0, Ciri::Forks::TangerineWhistle::Schema.new],
                     ]
                   when "EIP158"
                     [
                         [0, Ciri::Forks::SpuriousDragon::Schema.new],
                     ]
                   when "Byzantium"
                     [
                         [0, Ciri::Forks::Byzantium::Schema.new],
                     ]
                   when "Constantinople"
                     [
                         [0, Ciri::Forks::Constantinople::Schema.new],
                     ]
                   when "FrontierToHomesteadAt5"
                     [
                         [0, Ciri::Forks::Frontier::Schema.new],
                         [5, Ciri::Forks::Homestead::Schema.new(support_dao_fork: false)],
                     ]
                   when "HomesteadToEIP150At5"
                     [
                         [0, Ciri::Forks::Homestead::Schema.new(support_dao_fork: false)],
                         [5, Ciri::Forks::TangerineWhistle::Schema.new],
                     ]
                   when "HomesteadToDaoAt5"
                     [
                         [0, Ciri::Forks::Homestead::Schema.new(support_dao_fork: true, dao_fork_block_number: 5)],
                     ]
                   when "EIP158ToByzantiumAt5"
                     [
                         [0, Ciri::Forks::SpuriousDragon::Schema.new],
                         [5, Ciri::Forks::Byzantium::Schema.new],
                     ]
                   else
                     raise ArgumentError.new("unknown network: #{network}")
                   end

    Ciri::Forks::Config.new(schema_rules)
  end

  def prepare_state(state, fixture)
    fixture['pre'].each do |address, v|
      address = Ciri::Types::Address.new address.decode_hex

      account, code, storage = parse_account v
      state.set_balance(address, account.balance)
      state.set_nonce(address, account.nonce)
      state.set_account_code(address, code)

      storage.each do |k, v|
        key, value = k.decode_big_endian, v.decode_big_endian
        state.store(address, key, value)
      end
    end
  end

  def self.run_test_case(test_case, prefix: nil, tags: {})
    test_case.each do |name, t|

      # TODO support all forks
      next skip("#{prefix} #{name}") if name.include?("Constantinople")

      # register rspec test case
      it "#{prefix} #{name}", **tags.dup do
        db = Ciri::DB::Backend::Memory.new
        state = Ciri::State.new(db)
        # pre
        prepare_state(state, t)

        genesis = if t['genesisRLP']
                    Ciri::POWChain::Block.rlp_decode(t['genesisRLP'].decode_hex)
                  elsif t['genesisBlockHeader']
                    Ciri::POWChain::Block.new(header: parse_header(t['genesisBlockHeader']), transactions: [], ommers: [])
                  end

        fork_config = extract_fork_config(t)
        chain = Ciri::POWChain::Chain.new(db, genesis: genesis, network_id: 0, fork_config: fork_config)

        # run block
        t['blocks'].each do |b|
          begin
            block = Ciri::POWChain::Block.rlp_decode b['rlp'].decode_hex
            chain.import_block(block)
          rescue Ciri::POWChain::Chain::InvalidBlockError,
              Ciri::RLP::InvalidError,
              Ciri::EVM::Error,
              Ciri::Types::Errors::InvalidError => e
            p e
            expect(b['blockHeader']).to be_nil
            expect(b['transactions']).to be_nil
            expect(b['uncleHeaders']).to be_nil
            break
          end

          # check status
          block = chain.get_block(block.get_hash)
          expect(block.header).to eq fixture_to_block_header(b['blockHeader']) if b['blockHeader']
          expect(block.transactions).to eq b['transactions'].map {|t| fixture_to_transaction(t)} if b['transactions']
          expect(block.ommers).to eq b['uncleHeaders'].map {|h| fixture_to_block_header(h)} if b['uncleHeaders']

        end
      end

    end
  end

  slow_cases = %w{
    bcExploitTest/SuicideIssue
    bcExploitTest/ShanghaiLove
  }.map {|f| ["fixtures/BlockchainTests/#{f}.json", true]}.to_h

  slow_topics = %w{
  }.map {|f| ["fixtures/BlockchainTests/#{f}", true]}.to_h

  Dir.glob("fixtures/BlockchainTests/**").each do |topic|

    tags = {}
    # tag slow test topics
    if slow_topics.include?(topic)
      tags[:slow_tests] = true
    end

    Dir.glob("#{topic}/*.json").each do |t|
      tags = tags.dup
      # tag slow test cases
      if slow_cases.include?(t)
        tags[:slow_tests] = true
      end

      run_test_case(JSON.load(open t), prefix: topic, tags: tags)
    end
  end

  # Dir.glob("fixtures/BlockchainTests/GeneralStateTests/**/*.json").each do |topic|
  #   topic ||= nil
  #   run_test_case(JSON.load(open topic || 'fixtures/BlockchainTests/bcValidBlockTest/callRevert.json'), prefix: topic, tags: {})
  # end

end
