# Cloud Foundry Java Buildpack
# Copyright (c) 2013 the original author or authors.
#
# Licensed under the Apache License, Version 2.0 (the "License");
# you may not use this file except in compliance with the License.
# You may obtain a copy of the License at
#
#      http://www.apache.org/licenses/LICENSE-2.0
#
# Unless required by applicable law or agreed to in writing, software
# distributed under the License is distributed on an "AS IS" BASIS,
# WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
# See the License for the specific language governing permissions and
# limitations under the License.

require 'spec_helper'
require 'java_buildpack/jre/memory/memory_heuristics_openjdk_pre8'

module JavaBuildpack::Jre

  describe MemoryHeuristicsOpenJDKPre8 do

    PRE8_TEST_HEAP_WEIGHTING = 0.5
    PRE8_TEST_PERMGEN_WEIGHTING = 0.3
    PRE8_TEST_STACK_WEIGHTING = 0.1
    PRE8_TEST_NATIVE_WEIGHTING = 0.1
    PRE8_TEST_SMALL_NATIVE_WEIGHTING = 0.05

    let(:pre8_test_weightings) { heuristics({
      'heap' => PRE8_TEST_HEAP_WEIGHTING,
      'permgen' => PRE8_TEST_PERMGEN_WEIGHTING,
      'stack' => PRE8_TEST_STACK_WEIGHTING,
      'native' => PRE8_TEST_NATIVE_WEIGHTING
      }) }

    before do
      $stderr = StringIO.new
    end

    it 'should fail if the configured weightings sum to more than 1' do
      with_memory_limit('1m') do
        expect { MemoryHeuristicsOpenJDKPre8.new({}, heuristics({'heap' => 0.5, 'permgen' => 0.4, 'stack' => 0.1, 'native' => 0.1})) }
          .to raise_error(/Invalid/)
      end
    end

    it 'should fail if the heap weighting is less than 0' do
      with_memory_limit('1m') do
        expect { MemoryHeuristicsOpenJDKPre8.new({}, heuristics({'heap' => -0.1, 'permgen' => 0.3, 'stack' => 0.1, 'native' => 0.1})) }
          .to raise_error(/Invalid/)
      end
    end

    it 'should fail if the permgen weighting is less than 0' do
      with_memory_limit('1m') do
        expect { MemoryHeuristicsOpenJDKPre8.new({}, heuristics({'heap' => 0.5, 'permgen' => -0.3, 'stack' => 0.1, 'native' => 0.1})) }
          .to raise_error(/Invalid/)
      end
    end

    it 'should fail if the stack weighting is less than 0' do
      with_memory_limit('1m') do
        expect { MemoryHeuristicsOpenJDKPre8.new({}, heuristics({'heap' => 0.5, 'permgen' => 0.3, 'stack' => -0.1, 'native' => 0.1})) }
        .to raise_error(/Invalid/)
      end
    end

    it 'should fail if the native weighting is less than 0' do
      with_memory_limit('1m') do
        expect { MemoryHeuristicsOpenJDKPre8.new({}, heuristics({'heap' => 0.5, 'permgen' => 0.3, 'stack' => 0.1, 'native' => -0.1})) }
          .to raise_error(/Invalid/)
      end
    end

    it 'should fail if a configured weighting is invalid' do
      with_memory_limit('1m') do
        expect { MemoryHeuristicsOpenJDKPre8.new({}, heuristics({'heap' => PRE8_TEST_HEAP_WEIGHTING, 'permgen' => PRE8_TEST_PERMGEN_WEIGHTING, 'stack' => PRE8_TEST_STACK_WEIGHTING, 'native' => 'x'})) }
          .to raise_error(/Invalid/)
      end
    end

    it 'should default maximum heap size and permgen size according to the configured weightings' do
      with_memory_limit('1024m') do
        memory_heuristics = MemoryHeuristicsOpenJDKPre8.new({}, pre8_test_weightings)
        expect(memory_heuristics.output['heap']).to eq("#{(1024 * PRE8_TEST_HEAP_WEIGHTING).to_i.to_s}M")
        expect(memory_heuristics.output['permgen']).to eq("#{(1024 * 1024 * PRE8_TEST_PERMGEN_WEIGHTING).to_i.to_s}K")
      end
    end

    it 'should default the stack size regardless of the memory limit' do
      with_memory_limit('0m') do
        memory_heuristics = MemoryHeuristicsOpenJDKPre8.new({}, pre8_test_weightings)
        expect(memory_heuristics.output['stack']).to eq('1M')
      end
    end

    it 'should default maximum heap size and permgen size according to the configured weightings when the weightings sum to less than 1' do
      with_memory_limit('1024m') do
        memory_heuristics = MemoryHeuristicsOpenJDKPre8.new({}, heuristics({'heap' => PRE8_TEST_HEAP_WEIGHTING, 'permgen' => PRE8_TEST_PERMGEN_WEIGHTING, 'stack' => PRE8_TEST_STACK_WEIGHTING, 'native' => PRE8_TEST_SMALL_NATIVE_WEIGHTING}))
        expect(memory_heuristics.output['heap']).to eq("#{(1024 * PRE8_TEST_HEAP_WEIGHTING).to_i.to_s}M")
        expect(memory_heuristics.output['permgen']).to eq("#{(1024 * 1024 * PRE8_TEST_PERMGEN_WEIGHTING).to_i.to_s}K")
      end
    end

    it 'should default permgen size according to the configured weightings when maximum heap size is specified' do
      with_memory_limit('4096m') do
        memory_heuristics = MemoryHeuristicsOpenJDKPre8.new({'heap' => "#{(4096 * 3 / 4).to_i.to_s}m"}, pre8_test_weightings)
        expect(memory_heuristics.output['heap']).to eq('3G')
        expect(memory_heuristics.output['permgen']).to eq("#{(1024 * 4096 * PRE8_TEST_PERMGEN_WEIGHTING - 1024 * 1024 * PRE8_TEST_PERMGEN_WEIGHTING / (PRE8_TEST_PERMGEN_WEIGHTING + PRE8_TEST_NATIVE_WEIGHTING)).to_i.to_s}K")
      end
    end

    it 'should default maximum heap size according to the configured weightings when maximum permgen size is specified' do
      with_memory_limit('4096m') do
        memory_heuristics = MemoryHeuristicsOpenJDKPre8.new({'permgen' => "#{(4096 / 2).to_i.to_s}m"}, pre8_test_weightings)
        expect(memory_heuristics.output['permgen']).to eq('2G')
        expect(memory_heuristics.output['heap']).to eq("#{(1024 * 4096 * PRE8_TEST_HEAP_WEIGHTING - 1024 * 4096 * 0.2 * PRE8_TEST_HEAP_WEIGHTING / (PRE8_TEST_HEAP_WEIGHTING + PRE8_TEST_NATIVE_WEIGHTING)).to_i.to_s}K")
      end
    end

    it 'should default maximum heap size and permgen size according to the configured weightings when thread stack size is specified' do
      with_memory_limit('4096m') do
        memory_heuristics = MemoryHeuristicsOpenJDKPre8.new({'stack' => '2m'}, pre8_test_weightings)
        # The stack size is double the default, so this will consume an extra 409.6m, which should be taken from heap, permgen, and native according to their weightings
        expect(memory_heuristics.output['heap']).to eq("#{(1024 * 4096 * PRE8_TEST_HEAP_WEIGHTING - 1024 * 409.6 * PRE8_TEST_HEAP_WEIGHTING / (PRE8_TEST_HEAP_WEIGHTING + PRE8_TEST_PERMGEN_WEIGHTING + PRE8_TEST_NATIVE_WEIGHTING)).to_i.to_s}K")
        expect(memory_heuristics.output['permgen']).to eq("#{(1024 * 4096 * PRE8_TEST_PERMGEN_WEIGHTING - 1024 * 409.6 * PRE8_TEST_PERMGEN_WEIGHTING / (PRE8_TEST_PERMGEN_WEIGHTING + PRE8_TEST_HEAP_WEIGHTING + PRE8_TEST_NATIVE_WEIGHTING)).to_i.to_s}K")
      end
    end

    it 'should default permgen size according to the configured weightings when maximum heap size and thread stack size are specified' do
      with_memory_limit('4096m') do
        memory_heuristics = MemoryHeuristicsOpenJDKPre8.new({'heap' => "#{(4096 * 3 / 4).to_i.to_s}m", 'stack' => '2m'}, pre8_test_weightings)
        # The heap size is 1G more than the default, so this should be taken from permgen according to the weightings
        # The stack size is double the default, so this will consume an extra 409.6m, some of which should be taken from permgen according to the weightings
        expect(memory_heuristics.output['permgen']).to eq("#{(1024 * 4096 * PRE8_TEST_PERMGEN_WEIGHTING - 1024 * 1024 * PRE8_TEST_PERMGEN_WEIGHTING / (PRE8_TEST_PERMGEN_WEIGHTING + PRE8_TEST_NATIVE_WEIGHTING) -
            1024 * 409.6 * PRE8_TEST_PERMGEN_WEIGHTING / (PRE8_TEST_PERMGEN_WEIGHTING + PRE8_TEST_NATIVE_WEIGHTING)).to_i.to_s}K")
      end
    end

    it 'should not apply any defaults when maximum heap size, maximum permgen size, and thread stack size are specified' do
      with_memory_limit('4096m') do
        memory_heuristics = MemoryHeuristicsOpenJDKPre8.new({'heap' => '1m', 'permgen' => '1m', 'stack' => '2m'}, pre8_test_weightings)
        expect(memory_heuristics.output['heap']).to eq('1M')
        expect(memory_heuristics.output['permgen']).to eq('1M')
        expect(memory_heuristics.output['stack']).to eq('2M')
      end
    end

    it 'should only defaults the thread stack size when the memory limit is unknown' do
      with_memory_limit(nil) do
        memory_heuristics = MemoryHeuristicsOpenJDKPre8.new({}, pre8_test_weightings)
        expect(memory_heuristics.output['heap']).to be_nil
        expect(memory_heuristics.output['permgen']).to be_nil
        expect(memory_heuristics.output['stack']).to eq('1M')
      end
    end

    def heuristics(hash)
      {'pre_8' => hash}
    end

    def with_memory_limit(memory_limit)
      previous_value = ENV['MEMORY_LIMIT']
      begin
        ENV['MEMORY_LIMIT'] = memory_limit
        yield
      ensure
        ENV['MEMORY_LIMIT'] = previous_value
      end
    end

  end

end