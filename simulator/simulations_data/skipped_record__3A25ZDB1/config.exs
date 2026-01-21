%Simulator.EngineConfig{
  clients: [Simulator.NormalClient, Simulator.TLSClient],
  topics: [
    %{topic: "A442D3AE8CE988D98E73856B9E7B947F906683D5D35BBF022257B2747C30", partitions: 6},
    %{topic: "7EEAA041FCBFFCFB1DFE676EFA6CD64BC03784DF0C3326F1AB8451B97767", partitions: 11},
    %{topic: "5333C7C3855A872BEF8F5812209D849A8336B78AB54D5A28AD298EF95107", partitions: 7},
    %{topic: "BFBD0260BA02B81EFC02BF20D2ECDAEAA44490BD10F5744A0F5A3CB85CD2", partitions: 4},
    %{topic: "17A06A9E2B70472E0908AD7AA39C332653B51EB9D1FB9CAF59FCFAFF9AFE", partitions: 3},
    %{topic: "2E80B966016539ACAF3158608745EAF3869C02012C0B5FAB2874099D4B79", partitions: 9},
    %{topic: "935E08BA5C0045A4CA47E23A4679ADCCC6FEB6B6A8A2E79E3032AC9DCF4E", partitions: 10},
    %{topic: "AFBBFA2030270377A2ECE63644380BEB3848C17B04B1DDFA7E4ACA98D62D", partitions: 2}
  ],
  topics_replication_factor: 2,
  consumer_groups: [%{name: "SimulatorGroup1", max_consumers: 3}],
  consumer_group_configs: [
    [
      cg_mod: Simulator.Engine.Consumer.NormalClient0,
      isolation_level: :read_committed,
      committers_count: 1,
      rebalance_timeout_ms: 30000,
      client: Simulator.NormalClient,
      topics: [
        [
          name: "A442D3AE8CE988D98E73856B9E7B947F906683D5D35BBF022257B2747C30",
          isolation_level: :read_committed,
          fetch_interval_ms: 30000,
          fetch_max_bytes: 500_000,
          handler_cooldown_ms: 0,
          handler_max_batch_size: 100,
          handler_max_unacked_commits: 0,
          offset_reset_policy: :earliest
        ],
        [
          name: "7EEAA041FCBFFCFB1DFE676EFA6CD64BC03784DF0C3326F1AB8451B97767",
          isolation_level: :read_committed,
          fetch_interval_ms: 30000,
          fetch_max_bytes: 1_000_000,
          handler_cooldown_ms: 0,
          handler_max_batch_size: :dynamic,
          handler_max_unacked_commits: 0,
          max_queue_size: 20,
          offset_reset_policy: :earliest
        ],
        [
          name: "5333C7C3855A872BEF8F5812209D849A8336B78AB54D5A28AD298EF95107",
          isolation_level: :read_uncommitted,
          fetch_strategy:
            {:exclusive,
             [
               max_in_flight_requests: 3,
               linger_ms: 0,
               name: :tbd,
               max_wait_ms: 0,
               isolation_level: :read_uncommitted,
               request_timeout_ms: 30000,
               max_bytes_per_request: 1_000_000
             ]},
          fetch_interval_ms: 5000,
          fetch_max_bytes: 100_000,
          handler_cooldown_ms: 0,
          handler_max_batch_size: 200,
          handler_max_unacked_commits: 0,
          offset_reset_policy: :earliest
        ],
        [
          name: "BFBD0260BA02B81EFC02BF20D2ECDAEAA44490BD10F5744A0F5A3CB85CD2",
          isolation_level: :read_committed,
          fetch_interval_ms: 5000,
          fetch_max_bytes: 1_000_000,
          handler_cooldown_ms: 0,
          handler_max_batch_size: :dynamic,
          handler_max_unacked_commits: 0,
          offset_reset_policy: :earliest
        ],
        [
          name: "17A06A9E2B70472E0908AD7AA39C332653B51EB9D1FB9CAF59FCFAFF9AFE",
          isolation_level: :read_uncommitted,
          fetch_interval_ms: 10000,
          fetch_max_bytes: 1_000_000,
          handler_cooldown_ms: 0,
          handler_max_batch_size: 1000,
          handler_max_unacked_commits: 0,
          offset_reset_policy: :earliest
        ],
        [
          name: "2E80B966016539ACAF3158608745EAF3869C02012C0B5FAB2874099D4B79",
          isolation_level: :read_committed,
          fetch_interval_ms: 2500,
          fetch_max_bytes: 1_000_000,
          handler_cooldown_ms: 0,
          handler_max_batch_size: 100,
          handler_max_unacked_commits: 0,
          offset_reset_policy: :earliest
        ],
        [
          name: "935E08BA5C0045A4CA47E23A4679ADCCC6FEB6B6A8A2E79E3032AC9DCF4E",
          isolation_level: :read_committed,
          fetch_strategy: {:shared, :klife_default_fetcher},
          fetch_interval_ms: 30000,
          fetch_max_bytes: 1_000_000,
          handler_cooldown_ms: 0,
          handler_max_batch_size: :dynamic,
          handler_max_unacked_commits: 0,
          offset_reset_policy: :earliest
        ],
        [
          name: "AFBBFA2030270377A2ECE63644380BEB3848C17B04B1DDFA7E4ACA98D62D",
          isolation_level: :read_committed,
          fetch_strategy:
            {:exclusive,
             [
               max_in_flight_requests: 3,
               linger_ms: 0,
               name: :tbd,
               max_wait_ms: 0,
               isolation_level: :read_uncommitted,
               request_timeout_ms: 30000,
               max_bytes_per_request: 5_000_000
             ]},
          fetch_interval_ms: 5000,
          fetch_max_bytes: 1_000_000,
          handler_cooldown_ms: 0,
          handler_max_batch_size: 100,
          handler_max_unacked_commits: 0,
          offset_reset_policy: :earliest
        ]
      ],
      group_name: "SimulatorGroup1",
      fetch_strategy:
        {:exclusive,
         [
           max_in_flight_requests: 3,
           linger_ms: 0,
           name: :tbd,
           max_wait_ms: 0,
           isolation_level: :read_committed,
           request_timeout_ms: 20000,
           max_bytes_per_request: 250_000
         ]}
    ],
    [
      cg_mod: Simulator.Engine.Consumer.NormalClient1,
      isolation_level: :read_committed,
      committers_count: 1,
      rebalance_timeout_ms: 30000,
      client: Simulator.NormalClient,
      topics: [
        [
          name: "A442D3AE8CE988D98E73856B9E7B947F906683D5D35BBF022257B2747C30",
          isolation_level: :read_committed,
          fetch_interval_ms: 5000,
          fetch_max_bytes: 1_000_000,
          handler_cooldown_ms: 0,
          handler_max_batch_size: :dynamic,
          handler_max_unacked_commits: 0,
          max_queue_size: 10,
          offset_reset_policy: :earliest
        ],
        [
          name: "7EEAA041FCBFFCFB1DFE676EFA6CD64BC03784DF0C3326F1AB8451B97767",
          isolation_level: :read_committed,
          fetch_interval_ms: 5000,
          fetch_max_bytes: 500_000,
          handler_cooldown_ms: 0,
          handler_max_batch_size: :dynamic,
          handler_max_unacked_commits: 0,
          offset_reset_policy: :earliest
        ],
        [
          name: "5333C7C3855A872BEF8F5812209D849A8336B78AB54D5A28AD298EF95107",
          isolation_level: :read_committed,
          fetch_strategy:
            {:exclusive,
             [
               max_in_flight_requests: 3,
               linger_ms: 0,
               name: :tbd,
               max_wait_ms: 500,
               isolation_level: :read_committed,
               request_timeout_ms: 20000,
               max_bytes_per_request: 1_000_000
             ]},
          fetch_interval_ms: 2500,
          fetch_max_bytes: 1_000_000,
          handler_cooldown_ms: 0,
          handler_max_batch_size: 200,
          handler_max_unacked_commits: 0,
          max_queue_size: 20,
          offset_reset_policy: :earliest
        ],
        [
          name: "BFBD0260BA02B81EFC02BF20D2ECDAEAA44490BD10F5744A0F5A3CB85CD2",
          isolation_level: :read_committed,
          fetch_interval_ms: 5000,
          fetch_max_bytes: 1_000_000,
          handler_cooldown_ms: 0,
          handler_max_batch_size: :dynamic,
          handler_max_unacked_commits: 0,
          offset_reset_policy: :earliest
        ],
        [
          name: "17A06A9E2B70472E0908AD7AA39C332653B51EB9D1FB9CAF59FCFAFF9AFE",
          isolation_level: :read_uncommitted,
          fetch_interval_ms: 5000,
          fetch_max_bytes: 1_000_000,
          handler_cooldown_ms: 0,
          handler_max_batch_size: :dynamic,
          handler_max_unacked_commits: 0,
          offset_reset_policy: :earliest
        ],
        [
          name: "2E80B966016539ACAF3158608745EAF3869C02012C0B5FAB2874099D4B79",
          isolation_level: :read_committed,
          fetch_strategy: {:shared, :klife_default_fetcher},
          fetch_interval_ms: 5000,
          fetch_max_bytes: 1_000_000,
          handler_cooldown_ms: 0,
          handler_max_batch_size: :dynamic,
          handler_max_unacked_commits: 0,
          max_queue_size: 10,
          offset_reset_policy: :earliest
        ],
        [
          name: "935E08BA5C0045A4CA47E23A4679ADCCC6FEB6B6A8A2E79E3032AC9DCF4E",
          isolation_level: :read_committed,
          fetch_strategy: {:shared, :klife_default_fetcher},
          fetch_interval_ms: 30000,
          fetch_max_bytes: 1_000_000,
          handler_cooldown_ms: 0,
          handler_max_batch_size: :dynamic,
          handler_max_unacked_commits: 0,
          offset_reset_policy: :earliest
        ],
        [
          name: "AFBBFA2030270377A2ECE63644380BEB3848C17B04B1DDFA7E4ACA98D62D",
          isolation_level: :read_committed,
          fetch_interval_ms: 5000,
          fetch_max_bytes: 1_000_000,
          handler_cooldown_ms: 0,
          handler_max_batch_size: 100,
          handler_max_unacked_commits: 0,
          max_queue_size: 20,
          offset_reset_policy: :earliest
        ]
      ],
      group_name: "SimulatorGroup1",
      fetch_strategy:
        {:exclusive,
         [
           max_wait_ms: 0,
           isolation_level: :read_committed,
           request_timeout_ms: 30000,
           max_bytes_per_request: 5_000_000
         ]}
    ],
    [
      cg_mod: Simulator.Engine.Consumer.TLSClient2,
      isolation_level: :read_committed,
      committers_count: 1,
      rebalance_timeout_ms: 30000,
      client: Simulator.TLSClient,
      topics: [
        [
          name: "A442D3AE8CE988D98E73856B9E7B947F906683D5D35BBF022257B2747C30",
          isolation_level: :read_committed,
          fetch_strategy: {:shared, :klife_default_fetcher},
          fetch_interval_ms: 5000,
          fetch_max_bytes: 1_000_000,
          handler_cooldown_ms: 0,
          handler_max_batch_size: 100,
          handler_max_unacked_commits: 0,
          offset_reset_policy: :earliest
        ],
        [
          name: "7EEAA041FCBFFCFB1DFE676EFA6CD64BC03784DF0C3326F1AB8451B97767",
          isolation_level: :read_committed,
          fetch_interval_ms: 10000,
          fetch_max_bytes: 500_000,
          handler_cooldown_ms: 0,
          handler_max_batch_size: :dynamic,
          handler_max_unacked_commits: 0,
          offset_reset_policy: :earliest
        ],
        [
          name: "5333C7C3855A872BEF8F5812209D849A8336B78AB54D5A28AD298EF95107",
          isolation_level: :read_uncommitted,
          fetch_interval_ms: 1000,
          fetch_max_bytes: 1_000_000,
          handler_cooldown_ms: 0,
          handler_max_batch_size: :dynamic,
          handler_max_unacked_commits: 0,
          max_queue_size: 10,
          offset_reset_policy: :earliest
        ],
        [
          name: "BFBD0260BA02B81EFC02BF20D2ECDAEAA44490BD10F5744A0F5A3CB85CD2",
          isolation_level: :read_committed,
          fetch_strategy:
            {:exclusive,
             [
               max_in_flight_requests: 3,
               linger_ms: 0,
               name: :tbd,
               max_wait_ms: 500,
               isolation_level: :read_committed,
               request_timeout_ms: 30000,
               max_bytes_per_request: 500_000
             ]},
          fetch_interval_ms: 5000,
          fetch_max_bytes: 1_000_000,
          handler_cooldown_ms: 0,
          handler_max_batch_size: :dynamic,
          handler_max_unacked_commits: 0,
          offset_reset_policy: :earliest
        ],
        [
          name: "17A06A9E2B70472E0908AD7AA39C332653B51EB9D1FB9CAF59FCFAFF9AFE",
          isolation_level: :read_committed,
          fetch_interval_ms: 5000,
          fetch_max_bytes: 1_000_000,
          handler_cooldown_ms: 0,
          handler_max_batch_size: :dynamic,
          handler_max_unacked_commits: 0,
          offset_reset_policy: :earliest
        ],
        [
          name: "2E80B966016539ACAF3158608745EAF3869C02012C0B5FAB2874099D4B79",
          isolation_level: :read_committed,
          fetch_strategy: {:shared, :klife_default_fetcher},
          fetch_interval_ms: 5000,
          fetch_max_bytes: 500_000,
          handler_cooldown_ms: 0,
          handler_max_batch_size: 100,
          handler_max_unacked_commits: 0,
          offset_reset_policy: :earliest
        ],
        [
          name: "935E08BA5C0045A4CA47E23A4679ADCCC6FEB6B6A8A2E79E3032AC9DCF4E",
          isolation_level: :read_committed,
          fetch_strategy: {:shared, :klife_default_fetcher},
          fetch_interval_ms: 5000,
          fetch_max_bytes: 1_000_000,
          handler_cooldown_ms: 0,
          handler_max_batch_size: 1000,
          handler_max_unacked_commits: 0,
          max_queue_size: 10,
          offset_reset_policy: :earliest
        ],
        [
          name: "AFBBFA2030270377A2ECE63644380BEB3848C17B04B1DDFA7E4ACA98D62D",
          isolation_level: :read_committed,
          fetch_interval_ms: 2500,
          fetch_max_bytes: 100_000,
          handler_cooldown_ms: 0,
          handler_max_batch_size: 1000,
          handler_max_unacked_commits: 0,
          max_queue_size: 10,
          offset_reset_policy: :earliest
        ]
      ],
      group_name: "SimulatorGroup1",
      fetch_strategy: {:shared, :klife_default_fetcher}
    ]
  ],
  producer_max_rps: 80,
  producer_concurrency: 8,
  producer_loop_interval_ms: 1000,
  record_value_bytes: 957,
  record_key_bytes: 39,
  invariants_check_interval_ms: 5000,
  root_seed: {1_805_138_191, 12_876_587, 3_711_675_093},
  random_seeds_map: %{
    {:producer, "2E80B966016539ACAF3158608745EAF3869C02012C0B5FAB2874099D4B79", 8, 7} =>
      {1_501_472_916, 2_376_924_167, 1_148_943_349},
    {:producer, "935E08BA5C0045A4CA47E23A4679ADCCC6FEB6B6A8A2E79E3032AC9DCF4E", 7, 2} =>
      {1_733_602_340, 708_100_541, 2_736_586_404},
    {:producer, "17A06A9E2B70472E0908AD7AA39C332653B51EB9D1FB9CAF59FCFAFF9AFE", 2, 0} =>
      {2_480_073_545, 1_861_820_068, 3_202_539_721},
    {:producer, "7EEAA041FCBFFCFB1DFE676EFA6CD64BC03784DF0C3326F1AB8451B97767", 2, 0} =>
      {72_320_215, 766_428_951, 3_726_682_673},
    {:consumer, "A442D3AE8CE988D98E73856B9E7B947F906683D5D35BBF022257B2747C30", 3,
     "SimulatorGroup1", 1} => {2_998_789_669, 2_677_725_064, 1_996_204_551},
    {:consumer, "5333C7C3855A872BEF8F5812209D849A8336B78AB54D5A28AD298EF95107", 7,
     "SimulatorGroup1", 1} => {50_265_573, 930_174_986, 576_226_445},
    {:producer, "2E80B966016539ACAF3158608745EAF3869C02012C0B5FAB2874099D4B79", 5, 7} =>
      {2_756_220_548, 600_375_440, 2_039_853_117},
    {:producer, "7EEAA041FCBFFCFB1DFE676EFA6CD64BC03784DF0C3326F1AB8451B97767", 1, 0} =>
      {2_571_800_041, 4_270_183_676, 2_850_787_014},
    {:consumer, "AFBBFA2030270377A2ECE63644380BEB3848C17B04B1DDFA7E4ACA98D62D", 0,
     "SimulatorGroup1", 1} => {2_490_139_457, 4_052_530_667, 2_554_997_346},
    {:producer, "2E80B966016539ACAF3158608745EAF3869C02012C0B5FAB2874099D4B79", 6, 0} =>
      {3_734_058_607, 2_818_004_417, 2_478_921_538},
    {:producer, "5333C7C3855A872BEF8F5812209D849A8336B78AB54D5A28AD298EF95107", 0, 6} =>
      {1_505_617_436, 2_735_603_930, 3_255_536_895},
    {:consumer, "AFBBFA2030270377A2ECE63644380BEB3848C17B04B1DDFA7E4ACA98D62D", 2,
     "SimulatorGroup1", 0} => {3_172_946_334, 2_159_398_580, 4_095_704_815},
    {:consumer, "5333C7C3855A872BEF8F5812209D849A8336B78AB54D5A28AD298EF95107", 7,
     "SimulatorGroup1", 0} => {1_408_297_683, 4_044_232_745, 2_969_671_307},
    {:producer, "17A06A9E2B70472E0908AD7AA39C332653B51EB9D1FB9CAF59FCFAFF9AFE", 0, 1} =>
      {2_889_000_553, 1_663_181_883, 1_371_904_527},
    {:producer, "935E08BA5C0045A4CA47E23A4679ADCCC6FEB6B6A8A2E79E3032AC9DCF4E", 9, 2} =>
      {894_127_043, 2_037_591_432, 3_237_498_426},
    {:consumer, "A442D3AE8CE988D98E73856B9E7B947F906683D5D35BBF022257B2747C30", 6,
     "SimulatorGroup1", 1} => {2_543_422_752, 83_590_645, 2_485_483_731},
    {:producer, "7EEAA041FCBFFCFB1DFE676EFA6CD64BC03784DF0C3326F1AB8451B97767", 10, 6} =>
      {2_761_260_162, 3_024_745_717, 1_356_643_269},
    {:producer, "5333C7C3855A872BEF8F5812209D849A8336B78AB54D5A28AD298EF95107", 6, 5} =>
      {2_178_963_105, 2_008_599_269, 3_906_225_745},
    {:producer, "17A06A9E2B70472E0908AD7AA39C332653B51EB9D1FB9CAF59FCFAFF9AFE", 2, 4} =>
      {1_381_112_166, 1_386_795_901, 2_110_724_297},
    {:producer, "7EEAA041FCBFFCFB1DFE676EFA6CD64BC03784DF0C3326F1AB8451B97767", 1, 3} =>
      {1_487_945_447, 270_075_041, 2_731_357_480},
    {:producer, "2E80B966016539ACAF3158608745EAF3869C02012C0B5FAB2874099D4B79", 2, 6} =>
      {4_291_428_676, 58_831_010, 168_301_534},
    {:consumer, "A442D3AE8CE988D98E73856B9E7B947F906683D5D35BBF022257B2747C30", 2,
     "SimulatorGroup1", 2} => {1_216_342_240, 3_133_305_425, 1_698_886_544},
    {:producer, "BFBD0260BA02B81EFC02BF20D2ECDAEAA44490BD10F5744A0F5A3CB85CD2", 0, 2} =>
      {544_745_845, 2_681_721_401, 2_420_628_270},
    {:consumer, "935E08BA5C0045A4CA47E23A4679ADCCC6FEB6B6A8A2E79E3032AC9DCF4E", 1,
     "SimulatorGroup1", 2} => {2_494_641_986, 3_489_803_254, 2_876_379_852},
    {:producer, "5333C7C3855A872BEF8F5812209D849A8336B78AB54D5A28AD298EF95107", 3, 6} =>
      {1_101_122_868, 2_634_043_480, 2_180_106_189},
    {:producer, "7EEAA041FCBFFCFB1DFE676EFA6CD64BC03784DF0C3326F1AB8451B97767", 5, 2} =>
      {2_186_433_413, 4_193_919_657, 3_381_138_384},
    {:producer, "5333C7C3855A872BEF8F5812209D849A8336B78AB54D5A28AD298EF95107", 7, 2} =>
      {1_696_995_262, 2_500_015_366, 3_859_063_251},
    {:consumer, "935E08BA5C0045A4CA47E23A4679ADCCC6FEB6B6A8A2E79E3032AC9DCF4E", 2,
     "SimulatorGroup1", 0} => {810_365_573, 2_142_720_157, 2_798_079_621},
    {:consumer, "5333C7C3855A872BEF8F5812209D849A8336B78AB54D5A28AD298EF95107", 0,
     "SimulatorGroup1", 0} => {1_952_205_702, 625_542_825, 127_807_508},
    {:consumer, "7EEAA041FCBFFCFB1DFE676EFA6CD64BC03784DF0C3326F1AB8451B97767", 2,
     "SimulatorGroup1", 1} => {102_982_823, 2_407_618_594, 886_119_248},
    {:producer, "2E80B966016539ACAF3158608745EAF3869C02012C0B5FAB2874099D4B79", 9, 4} =>
      {794_543_817, 2_726_501_190, 1_663_981_755},
    {:producer, "7EEAA041FCBFFCFB1DFE676EFA6CD64BC03784DF0C3326F1AB8451B97767", 4, 2} =>
      {94_881_796, 208_727_277, 2_151_172_452},
    {:producer, "BFBD0260BA02B81EFC02BF20D2ECDAEAA44490BD10F5744A0F5A3CB85CD2", 0, 0} =>
      {1_107_024_589, 3_798_431_559, 7_570_652},
    {:consumer, "AFBBFA2030270377A2ECE63644380BEB3848C17B04B1DDFA7E4ACA98D62D", 2,
     "SimulatorGroup1", 2} => {2_905_058_769, 2_183_557_962, 1_920_333_111},
    {:consumer, "7EEAA041FCBFFCFB1DFE676EFA6CD64BC03784DF0C3326F1AB8451B97767", 11,
     "SimulatorGroup1", 0} => {361_028_473, 3_693_856_182, 2_597_720_129},
    {:producer, "2E80B966016539ACAF3158608745EAF3869C02012C0B5FAB2874099D4B79", 6, 7} =>
      {3_440_761_036, 2_584_360_237, 2_289_486_444},
    {:producer, "5333C7C3855A872BEF8F5812209D849A8336B78AB54D5A28AD298EF95107", 5, 3} =>
      {1_538_870_410, 2_868_924_280, 2_911_662_163},
    {:producer, "2E80B966016539ACAF3158608745EAF3869C02012C0B5FAB2874099D4B79", 1, 5} =>
      {2_716_238_116, 1_517_967_506, 1_996_789_831},
    {:producer, "A442D3AE8CE988D98E73856B9E7B947F906683D5D35BBF022257B2747C30", 1, 0} =>
      {3_012_877_500, 2_683_032_595, 3_950_687_013},
    {:producer, "2E80B966016539ACAF3158608745EAF3869C02012C0B5FAB2874099D4B79", 0, 0} =>
      {3_096_198_774, 951_883_668, 2_411_543_939},
    {:consumer, "935E08BA5C0045A4CA47E23A4679ADCCC6FEB6B6A8A2E79E3032AC9DCF4E", 10,
     "SimulatorGroup1", 2} => {1_111_642_857, 3_963_581_197, 1_227_782_470},
    {:consumer, "935E08BA5C0045A4CA47E23A4679ADCCC6FEB6B6A8A2E79E3032AC9DCF4E", 9,
     "SimulatorGroup1", 0} => {1_079_100_629, 1_289_887_622, 2_738_235_752},
    {:producer, "BFBD0260BA02B81EFC02BF20D2ECDAEAA44490BD10F5744A0F5A3CB85CD2", 0, 7} =>
      {4_085_672_006, 3_737_924_770, 959_086_694},
    {:producer, "7EEAA041FCBFFCFB1DFE676EFA6CD64BC03784DF0C3326F1AB8451B97767", 0, 7} =>
      {2_603_548_177, 2_008_796_489, 2_714_518_470},
    {:producer, "935E08BA5C0045A4CA47E23A4679ADCCC6FEB6B6A8A2E79E3032AC9DCF4E", 6, 4} =>
      {3_347_150_753, 3_855_999_378, 1_386_098_963},
    {:producer, "7EEAA041FCBFFCFB1DFE676EFA6CD64BC03784DF0C3326F1AB8451B97767", 11, 1} =>
      {252_474_964, 2_994_709_039, 1_966_273_980},
    {:consumer, "A442D3AE8CE988D98E73856B9E7B947F906683D5D35BBF022257B2747C30", 4,
     "SimulatorGroup1", 0} => {2_983_795_908, 1_590_336_783, 1_778_884_309},
    {:producer, "935E08BA5C0045A4CA47E23A4679ADCCC6FEB6B6A8A2E79E3032AC9DCF4E", 0, 2} =>
      {172_393_109, 2_644_644_631, 1_479_238_919},
    {:producer, "A442D3AE8CE988D98E73856B9E7B947F906683D5D35BBF022257B2747C30", 0, 5} =>
      {2_150_048_948, 2_574_867_750, 21_991_716},
    {:producer, "AFBBFA2030270377A2ECE63644380BEB3848C17B04B1DDFA7E4ACA98D62D", 1, 4} =>
      {64_510_175, 3_840_224_974, 1_233_881_643},
    {:producer, "17A06A9E2B70472E0908AD7AA39C332653B51EB9D1FB9CAF59FCFAFF9AFE", 1, 3} =>
      {2_598_589_882, 417_444_987, 3_104_734_140},
    {:consumer, "17A06A9E2B70472E0908AD7AA39C332653B51EB9D1FB9CAF59FCFAFF9AFE", 0,
     "SimulatorGroup1", 0} => {3_047_630_158, 2_901_730_344, 1_973_364_119},
    {:producer, "BFBD0260BA02B81EFC02BF20D2ECDAEAA44490BD10F5744A0F5A3CB85CD2", 2, 2} =>
      {85_062_734, 2_426_919_800, 3_415_764_967},
    {:producer, "2E80B966016539ACAF3158608745EAF3869C02012C0B5FAB2874099D4B79", 0, 4} =>
      {2_075_224_409, 4_146_994_220, 3_843_725_799},
    {:producer, "7EEAA041FCBFFCFB1DFE676EFA6CD64BC03784DF0C3326F1AB8451B97767", 6, 4} =>
      {1_676_340_559, 1_347_197_481, 3_880_753_179},
    {:producer, "BFBD0260BA02B81EFC02BF20D2ECDAEAA44490BD10F5744A0F5A3CB85CD2", 2, 0} =>
      {3_282_499_086, 893_451_733, 2_028_412_007},
    {:consumer, "A442D3AE8CE988D98E73856B9E7B947F906683D5D35BBF022257B2747C30", 3,
     "SimulatorGroup1", 2} => {2_075_134_465, 4_089_926_755, 941_531_658},
    {:consumer, "935E08BA5C0045A4CA47E23A4679ADCCC6FEB6B6A8A2E79E3032AC9DCF4E", 2,
     "SimulatorGroup1", 2} => {1_283_379_613, 232_289_406, 3_430_947_149},
    {:producer, "A442D3AE8CE988D98E73856B9E7B947F906683D5D35BBF022257B2747C30", 1, 1} =>
      {3_457_551_518, 3_351_903_672, 1_806_291_838},
    {:producer, "A442D3AE8CE988D98E73856B9E7B947F906683D5D35BBF022257B2747C30", 0, 6} =>
      {1_790_842_260, 3_784_730_314, 3_099_267_333},
    {:consumer, "5333C7C3855A872BEF8F5812209D849A8336B78AB54D5A28AD298EF95107", 0,
     "SimulatorGroup1", 1} => {677_243_340, 4_094_074_907, 2_432_215_436},
    {:producer, "7EEAA041FCBFFCFB1DFE676EFA6CD64BC03784DF0C3326F1AB8451B97767", 0, 1} =>
      {1_374_933_061, 3_489_745_348, 1_862_238_336},
    {:consumer, "A442D3AE8CE988D98E73856B9E7B947F906683D5D35BBF022257B2747C30", 3,
     "SimulatorGroup1", 0} => {2_362_481_774, 644_522_120, 1_817_816_198},
    {:consumer, "7EEAA041FCBFFCFB1DFE676EFA6CD64BC03784DF0C3326F1AB8451B97767", 10,
     "SimulatorGroup1", 0} => {416_789_977, 257_577_198, 843_933_775},
    {:producer, "935E08BA5C0045A4CA47E23A4679ADCCC6FEB6B6A8A2E79E3032AC9DCF4E", 1, 6} =>
      {3_743_419_588, 780_685_828, 4_004_286_945},
    {:producer, "2E80B966016539ACAF3158608745EAF3869C02012C0B5FAB2874099D4B79", 5, 2} =>
      {801_614_269, 2_917_189_031, 1_321_050_893},
    {:producer, "935E08BA5C0045A4CA47E23A4679ADCCC6FEB6B6A8A2E79E3032AC9DCF4E", 6, 6} =>
      {3_860_242_660, 2_695_888_073, 1_285_757_469},
    {:consumer, "935E08BA5C0045A4CA47E23A4679ADCCC6FEB6B6A8A2E79E3032AC9DCF4E", 0,
     "SimulatorGroup1", 0} => {479_785_844, 932_147_029, 3_847_180_203},
    {:consumer, "5333C7C3855A872BEF8F5812209D849A8336B78AB54D5A28AD298EF95107", 0,
     "SimulatorGroup1", 2} => {3_377_713_741, 2_008_584_849, 1_716_632_436},
    {:consumer, "5333C7C3855A872BEF8F5812209D849A8336B78AB54D5A28AD298EF95107", 2,
     "SimulatorGroup1", 1} => {3_863_213_531, 4_056_723_117, 217_477_111},
    {:producer, "2E80B966016539ACAF3158608745EAF3869C02012C0B5FAB2874099D4B79", 7, 7} =>
      {3_827_187_999, 2_295_223_868, 2_240_278_605},
    {:producer, "17A06A9E2B70472E0908AD7AA39C332653B51EB9D1FB9CAF59FCFAFF9AFE", 3, 4} =>
      {347_938_203, 1_307_940_992, 3_994_149_525},
    {:producer, "A442D3AE8CE988D98E73856B9E7B947F906683D5D35BBF022257B2747C30", 3, 1} =>
      {4_021_143_746, 3_198_261_141, 3_912_587_639},
    {:consumer, "A442D3AE8CE988D98E73856B9E7B947F906683D5D35BBF022257B2747C30", 5,
     "SimulatorGroup1", 1} => {2_535_211_192, 3_421_790_483, 361_275_710},
    {:producer, "A442D3AE8CE988D98E73856B9E7B947F906683D5D35BBF022257B2747C30", 1, 7} =>
      {2_943_887_573, 2_619_303_892, 3_617_050_258},
    {:producer, "935E08BA5C0045A4CA47E23A4679ADCCC6FEB6B6A8A2E79E3032AC9DCF4E", 1, 3} =>
      {2_797_806_544, 3_840_247_605, 3_870_428_131},
    {:producer, "2E80B966016539ACAF3158608745EAF3869C02012C0B5FAB2874099D4B79", 7, 5} =>
      {3_912_842_004, 3_206_504_609, 877_741_683},
    {:consumer, "7EEAA041FCBFFCFB1DFE676EFA6CD64BC03784DF0C3326F1AB8451B97767", 4,
     "SimulatorGroup1", 0} => {2_893_469_964, 3_641_888_738, 3_056_396_182},
    {:producer, "935E08BA5C0045A4CA47E23A4679ADCCC6FEB6B6A8A2E79E3032AC9DCF4E", 0, 5} =>
      {3_080_445_738, 4_051_354_147, 1_564_929_984},
    {:producer, "17A06A9E2B70472E0908AD7AA39C332653B51EB9D1FB9CAF59FCFAFF9AFE", 2, 7} =>
      {1_546_749_305, 2_806_189_448, 2_223_459_535},
    {:producer, "5333C7C3855A872BEF8F5812209D849A8336B78AB54D5A28AD298EF95107", 4, 1} =>
      {611_025_735, 3_591_598_110, 2_494_959_013},
    {:producer, "5333C7C3855A872BEF8F5812209D849A8336B78AB54D5A28AD298EF95107", 7, 6} =>
      {3_035_992_346, 1_786_766_877, 4_001_462_576},
    {:producer, "7EEAA041FCBFFCFB1DFE676EFA6CD64BC03784DF0C3326F1AB8451B97767", 10, 4} =>
      {2_310_257_418, 149_835_994, 718_085_958},
    {:consumer, "7EEAA041FCBFFCFB1DFE676EFA6CD64BC03784DF0C3326F1AB8451B97767", 9,
     "SimulatorGroup1", 1} => {222_834_381, 1_570_346_446, 2_524_006_797},
    {:producer, "7EEAA041FCBFFCFB1DFE676EFA6CD64BC03784DF0C3326F1AB8451B97767", 9, 6} =>
      {436_207_449, 1_552_958_959, 1_391_987_571},
    {:consumer, "7EEAA041FCBFFCFB1DFE676EFA6CD64BC03784DF0C3326F1AB8451B97767", 1,
     "SimulatorGroup1", 1} => {898_744_446, 2_679_907_533, 245_653_164},
    {:producer, "935E08BA5C0045A4CA47E23A4679ADCCC6FEB6B6A8A2E79E3032AC9DCF4E", 4, 4} =>
      {1_286_005_831, 2_904_660_444, 1_728_525_369},
    {:producer, "935E08BA5C0045A4CA47E23A4679ADCCC6FEB6B6A8A2E79E3032AC9DCF4E", 2, 4} =>
      {2_335_900_750, 972_499_230, 1_419_094_734},
    {:producer, "5333C7C3855A872BEF8F5812209D849A8336B78AB54D5A28AD298EF95107", 4, 5} =>
      {2_266_624_493, 622_126_626, 3_062_207_230},
    {:consumer, "2E80B966016539ACAF3158608745EAF3869C02012C0B5FAB2874099D4B79", 5,
     "SimulatorGroup1", 1} => {1_828_764_465, 3_060_129_414, 4_212_762_210},
    {:producer, "5333C7C3855A872BEF8F5812209D849A8336B78AB54D5A28AD298EF95107", 6, 1} =>
      {3_655_645_450, 3_919_567_721, 2_315_217_477},
    {:producer, "A442D3AE8CE988D98E73856B9E7B947F906683D5D35BBF022257B2747C30", 5, 1} =>
      {1_860_250_473, 3_025_305_924, 1_038_529_375},
    {:producer, "2E80B966016539ACAF3158608745EAF3869C02012C0B5FAB2874099D4B79", 0, 2} =>
      {3_494_884_646, 1_040_269_506, 329_885_271},
    {:producer, "A442D3AE8CE988D98E73856B9E7B947F906683D5D35BBF022257B2747C30", 3, 4} =>
      {1_980_054_372, 3_985_106_121, 4_246_546_766},
    {:producer, "BFBD0260BA02B81EFC02BF20D2ECDAEAA44490BD10F5744A0F5A3CB85CD2", 4, 0} =>
      {2_687_674_533, 789_085_885, 1_095_508_051},
    {:producer, "935E08BA5C0045A4CA47E23A4679ADCCC6FEB6B6A8A2E79E3032AC9DCF4E", 3, 4} =>
      {3_261_364_898, 1_958_843_385, 1_784_586_518},
    {:producer, "7EEAA041FCBFFCFB1DFE676EFA6CD64BC03784DF0C3326F1AB8451B97767", 5, 7} =>
      {237_913_403, 2_193_579_247, 626_751_956},
    {:consumer, "7EEAA041FCBFFCFB1DFE676EFA6CD64BC03784DF0C3326F1AB8451B97767", 10,
     "SimulatorGroup1", 2} => {3_949_461_921, 165_966_498, 1_274_840_626},
    {:producer, "7EEAA041FCBFFCFB1DFE676EFA6CD64BC03784DF0C3326F1AB8451B97767", 6, 7} =>
      {3_601_009_414, 1_853_145_393, 3_432_538_336},
    {:producer, "2E80B966016539ACAF3158608745EAF3869C02012C0B5FAB2874099D4B79", 5, 1} =>
      {455_264_532, 779_104_227, 1_733_661_798},
    {:producer, "7EEAA041FCBFFCFB1DFE676EFA6CD64BC03784DF0C3326F1AB8451B97767", 4, 4} =>
      {2_402_193_345, 172_241_332, 3_116_249_127},
    {:producer, "5333C7C3855A872BEF8F5812209D849A8336B78AB54D5A28AD298EF95107", 2, 4} =>
      {975_356_101, 2_803_435_830, 813_614_461},
    {:consumer, "2E80B966016539ACAF3158608745EAF3869C02012C0B5FAB2874099D4B79", 1,
     "SimulatorGroup1", 2} => {3_878_516_047, 1_780_506_269, 2_903_277_602},
    {:consumer, "17A06A9E2B70472E0908AD7AA39C332653B51EB9D1FB9CAF59FCFAFF9AFE", 3,
     "SimulatorGroup1", 0} => {1_116_152_322, 274_736_395, 3_230_984_250},
    {:consumer, "2E80B966016539ACAF3158608745EAF3869C02012C0B5FAB2874099D4B79", 0,
     "SimulatorGroup1", 2} => {662_281_462, 1_910_769_765, 1_812_661_099},
    {:producer, "BFBD0260BA02B81EFC02BF20D2ECDAEAA44490BD10F5744A0F5A3CB85CD2", 3, 5} =>
      {1_471_183_826, 1_318_153_763, 3_726_911_045},
    {:producer, "7EEAA041FCBFFCFB1DFE676EFA6CD64BC03784DF0C3326F1AB8451B97767", 1, 7} =>
      {223_899_924, 4_004_933_877, 3_865_241_902},
    {:producer, "5333C7C3855A872BEF8F5812209D849A8336B78AB54D5A28AD298EF95107", 3, 0} =>
      {4_099_710_377, 245_831_261, 130_582_185},
    {:consumer, "2E80B966016539ACAF3158608745EAF3869C02012C0B5FAB2874099D4B79", 2,
     "SimulatorGroup1", 2} => {3_630_525_520, 1_998_886_054, 3_167_909_383},
    {:producer, "A442D3AE8CE988D98E73856B9E7B947F906683D5D35BBF022257B2747C30", 0, 0} =>
      {1_626_385_567, 2_123_792_561, 2_426_477_086},
    {:producer, "5333C7C3855A872BEF8F5812209D849A8336B78AB54D5A28AD298EF95107", 0, 3} =>
      {3_526_616_022, 4_058_495_047, 712_150_437},
    {:producer, "AFBBFA2030270377A2ECE63644380BEB3848C17B04B1DDFA7E4ACA98D62D", 1, 5} =>
      {1_283_587_477, 3_439_393_888, 3_178_678_072},
    {:producer, "5333C7C3855A872BEF8F5812209D849A8336B78AB54D5A28AD298EF95107", 6, 4} =>
      {289_879_720, 1_820_566_129, 2_082_547_692},
    {:producer, "5333C7C3855A872BEF8F5812209D849A8336B78AB54D5A28AD298EF95107", 1, 6} =>
      {1_440_163_455, 90_087_479, 4_017_597_539},
    {:producer, "935E08BA5C0045A4CA47E23A4679ADCCC6FEB6B6A8A2E79E3032AC9DCF4E", 6, 1} =>
      {3_641_032_268, 1_938_202_182, 2_602_936_455},
    {:consumer, "17A06A9E2B70472E0908AD7AA39C332653B51EB9D1FB9CAF59FCFAFF9AFE", 3,
     "SimulatorGroup1", 2} => {1_248_307_685, 3_816_385_074, 1_768_029_110},
    {:producer, "17A06A9E2B70472E0908AD7AA39C332653B51EB9D1FB9CAF59FCFAFF9AFE", 3, 2} =>
      {927_633_780, 1_454_420_139, 1_304_187_217},
    {:producer, "AFBBFA2030270377A2ECE63644380BEB3848C17B04B1DDFA7E4ACA98D62D", 2, 2} =>
      {1_120_400_381, 2_061_721_074, 924_813_634},
    {:producer, "5333C7C3855A872BEF8F5812209D849A8336B78AB54D5A28AD298EF95107", 7, 7} =>
      {110_924_982, 3_522_626_259, 2_491_277_307},
    {:consumer, "935E08BA5C0045A4CA47E23A4679ADCCC6FEB6B6A8A2E79E3032AC9DCF4E", 9,
     "SimulatorGroup1", 1} => {858_840_782, 767_092_713, 3_646_672_756},
    {:producer, "5333C7C3855A872BEF8F5812209D849A8336B78AB54D5A28AD298EF95107", 6, 3} =>
      {910_039_006, 2_122_618_687, 2_921_840_612},
    {:producer, "AFBBFA2030270377A2ECE63644380BEB3848C17B04B1DDFA7E4ACA98D62D", 0, 2} =>
      {3_396_765_877, 4_046_789_943, 3_301_330_635},
    {:producer, "7EEAA041FCBFFCFB1DFE676EFA6CD64BC03784DF0C3326F1AB8451B97767", 4, 0} =>
      {2_255_352_849, 1_077_374_380, 2_886_824_676},
    {:consumer, "7EEAA041FCBFFCFB1DFE676EFA6CD64BC03784DF0C3326F1AB8451B97767", 8,
     "SimulatorGroup1", 1} => {1_070_407_365, 398_616_998, 3_088_588_584},
    {:producer, "7EEAA041FCBFFCFB1DFE676EFA6CD64BC03784DF0C3326F1AB8451B97767", 2, 4} =>
      {2_436_217_309, 1_315_529_562, 3_101_282_916},
    {:producer, "935E08BA5C0045A4CA47E23A4679ADCCC6FEB6B6A8A2E79E3032AC9DCF4E", 2, 5} =>
      {304_453_747, 3_434_001_989, 237_465_743},
    {:producer, "17A06A9E2B70472E0908AD7AA39C332653B51EB9D1FB9CAF59FCFAFF9AFE", 1, 5} =>
      {1_854_411_353, 3_654_227_229, 1_409_168_061},
    {:producer, "BFBD0260BA02B81EFC02BF20D2ECDAEAA44490BD10F5744A0F5A3CB85CD2", 1, 1} =>
      {1_658_177_333, 400_526_879, 4_186_567_296},
    {:producer, "2E80B966016539ACAF3158608745EAF3869C02012C0B5FAB2874099D4B79", 3, 4} =>
      {2_514_630_612, 138_465_157, 1_953_235_730},
    {:consumer, "7EEAA041FCBFFCFB1DFE676EFA6CD64BC03784DF0C3326F1AB8451B97767", 1,
     "SimulatorGroup1", 0} => {657_386_171, 1_592_162_672, 2_049_848_573},
    {:producer, "7EEAA041FCBFFCFB1DFE676EFA6CD64BC03784DF0C3326F1AB8451B97767", 8, 2} =>
      {920_820_667, 3_943_560_927, 1_079_073_089},
    {:producer, "2E80B966016539ACAF3158608745EAF3869C02012C0B5FAB2874099D4B79", 4, 7} =>
      {4_053_589_145, 30_655_816, 3_734_905_065},
    {:producer, "AFBBFA2030270377A2ECE63644380BEB3848C17B04B1DDFA7E4ACA98D62D", 0, 7} =>
      {1_247_708_871, 844_123_605, 3_505_250_687},
    {:producer, "17A06A9E2B70472E0908AD7AA39C332653B51EB9D1FB9CAF59FCFAFF9AFE", 3, 3} =>
      {2_718_289_116, 1_666_245_364, 2_208_766_926},
    {:consumer, "5333C7C3855A872BEF8F5812209D849A8336B78AB54D5A28AD298EF95107", 3,
     "SimulatorGroup1", 1} => {2_971_713_149, 2_394_155_025, 3_823_317_073},
    {:producer, "7EEAA041FCBFFCFB1DFE676EFA6CD64BC03784DF0C3326F1AB8451B97767", 0, 4} =>
      {3_797_477_957, 3_391_176_131, 3_920_714_134},
    {:producer, "935E08BA5C0045A4CA47E23A4679ADCCC6FEB6B6A8A2E79E3032AC9DCF4E", 4, 5} =>
      {510_191_311, 1_443_581_542, 84_120_075},
    {:producer, "17A06A9E2B70472E0908AD7AA39C332653B51EB9D1FB9CAF59FCFAFF9AFE", 2, 2} =>
      {4_255_869_810, 4_160_797_617, 3_810_116_073},
    {:consumer, "7EEAA041FCBFFCFB1DFE676EFA6CD64BC03784DF0C3326F1AB8451B97767", 11,
     "SimulatorGroup1", 1} => {97_708_569, 3_307_941_247, 1_748_575_004},
    {:producer, "7EEAA041FCBFFCFB1DFE676EFA6CD64BC03784DF0C3326F1AB8451B97767", 11, 7} =>
      {3_490_608_329, 2_229_169_607, 4_261_002_597},
    {:producer, "5333C7C3855A872BEF8F5812209D849A8336B78AB54D5A28AD298EF95107", 1, 7} =>
      {3_559_119_633, 2_189_254_765, 3_532_543_615},
    {:producer, "935E08BA5C0045A4CA47E23A4679ADCCC6FEB6B6A8A2E79E3032AC9DCF4E", 8, 7} =>
      {4_147_191_680, 1_029_573_035, 2_027_082_312},
    {:producer, "2E80B966016539ACAF3158608745EAF3869C02012C0B5FAB2874099D4B79", 4, 0} =>
      {1_005_242_439, 491_693_884, 748_288_113},
    {:producer, "7EEAA041FCBFFCFB1DFE676EFA6CD64BC03784DF0C3326F1AB8451B97767", 8, 0} =>
      {1_540_869_554, 3_223_711_983, 1_315_651_613},
    {:consumer, "17A06A9E2B70472E0908AD7AA39C332653B51EB9D1FB9CAF59FCFAFF9AFE", 2,
     "SimulatorGroup1", 1} => {2_940_891_492, 309_992_219, 1_133_338_823},
    {:producer, "A442D3AE8CE988D98E73856B9E7B947F906683D5D35BBF022257B2747C30", 3, 5} =>
      {1_168_045_467, 3_209_341_740, 1_714_174_590},
    {:producer, "A442D3AE8CE988D98E73856B9E7B947F906683D5D35BBF022257B2747C30", 0, 2} =>
      {2_795_192_730, 3_246_234_587, 720_769_385},
    {:producer, "7EEAA041FCBFFCFB1DFE676EFA6CD64BC03784DF0C3326F1AB8451B97767", 3, 5} =>
      {2_165_380_867, 2_944_508_059, 2_608_787_577},
    {:producer, "2E80B966016539ACAF3158608745EAF3869C02012C0B5FAB2874099D4B79", 3, 7} =>
      {2_763_562_466, 1_722_005_086, 930_384_190},
    {:consumer, "935E08BA5C0045A4CA47E23A4679ADCCC6FEB6B6A8A2E79E3032AC9DCF4E", 2,
     "SimulatorGroup1", 1} => {277_966_761, 2_958_879_096, 1_051_663_426},
    {:consumer, "BFBD0260BA02B81EFC02BF20D2ECDAEAA44490BD10F5744A0F5A3CB85CD2", 4,
     "SimulatorGroup1", 1} => {2_667_813_289, 906_362_842, 3_682_440_419},
    {:consumer, "5333C7C3855A872BEF8F5812209D849A8336B78AB54D5A28AD298EF95107", 5,
     "SimulatorGroup1", 1} => {265_054_654, 1_174_367_185, 906_171_320},
    {:producer, "5333C7C3855A872BEF8F5812209D849A8336B78AB54D5A28AD298EF95107", 0, 4} =>
      {3_620_539_025, 1_422_755_145, 1_131_643_488},
    {:producer, "5333C7C3855A872BEF8F5812209D849A8336B78AB54D5A28AD298EF95107", 0, 1} =>
      {3_145_449_213, 2_174_748_278, 510_021_316},
    {:producer, "7EEAA041FCBFFCFB1DFE676EFA6CD64BC03784DF0C3326F1AB8451B97767", 2, 7} =>
      {2_775_122_828, 1_612_650_954, 3_359_943_333},
    {:producer, "7EEAA041FCBFFCFB1DFE676EFA6CD64BC03784DF0C3326F1AB8451B97767", 3, 1} =>
      {1_064_486_162, 2_601_745_378, 3_982_235_436},
    {:consumer, "935E08BA5C0045A4CA47E23A4679ADCCC6FEB6B6A8A2E79E3032AC9DCF4E", 1,
     "SimulatorGroup1", 1} => {978_660_762, 1_003_866_042, 4_004_173_303},
    {:producer, "2E80B966016539ACAF3158608745EAF3869C02012C0B5FAB2874099D4B79", 7, 1} =>
      {2_735_816_334, 2_994_579_491, 2_110_528_070},
    {:producer, "2E80B966016539ACAF3158608745EAF3869C02012C0B5FAB2874099D4B79", 3, 2} =>
      {2_203_472_952, 1_746_078_133, 2_879_798_388},
    {:producer, "7EEAA041FCBFFCFB1DFE676EFA6CD64BC03784DF0C3326F1AB8451B97767", 7, 2} =>
      {1_379_662_819, 846_422_758, 2_054_450_426},
    {:producer, "BFBD0260BA02B81EFC02BF20D2ECDAEAA44490BD10F5744A0F5A3CB85CD2", 4, 5} =>
      {3_867_688_622, 4_059_391_237, 2_025_706_295},
    {:producer, "7EEAA041FCBFFCFB1DFE676EFA6CD64BC03784DF0C3326F1AB8451B97767", 6, 0} =>
      {2_789_381_020, 2_298_709_582, 1_755_009_760},
    {:producer, "A442D3AE8CE988D98E73856B9E7B947F906683D5D35BBF022257B2747C30", 4, 6} =>
      {426_593_512, 3_761_087_388, 1_129_795_937},
    {:producer, "2E80B966016539ACAF3158608745EAF3869C02012C0B5FAB2874099D4B79", 6, 6} =>
      {1_424_430_390, 2_911_603_064, 2_375_201_091},
    {:producer, "2E80B966016539ACAF3158608745EAF3869C02012C0B5FAB2874099D4B79", 8, 2} =>
      {83_489_955, 3_538_508_439, 4_031_945_246},
    {:producer, "A442D3AE8CE988D98E73856B9E7B947F906683D5D35BBF022257B2747C30", 0, 7} =>
      {1_232_029_328, 619_023_565, 1_100_670_473},
    {:producer, "BFBD0260BA02B81EFC02BF20D2ECDAEAA44490BD10F5744A0F5A3CB85CD2", 1, 2} =>
      {3_958_522_312, 135_757_428, 1_101_557_443},
    {:producer, "AFBBFA2030270377A2ECE63644380BEB3848C17B04B1DDFA7E4ACA98D62D", 2, 6} =>
      {2_230_266_127, 9_271_122, 4_134_591_521},
    {:consumer, "935E08BA5C0045A4CA47E23A4679ADCCC6FEB6B6A8A2E79E3032AC9DCF4E", 4,
     "SimulatorGroup1", 1} => {2_527_889_880, 2_397_334_330, 2_677_449_470},
    {:producer, "7EEAA041FCBFFCFB1DFE676EFA6CD64BC03784DF0C3326F1AB8451B97767", 5, 1} =>
      {2_580_039_791, 1_888_566_689, 2_932_137_386},
    {:producer, "2E80B966016539ACAF3158608745EAF3869C02012C0B5FAB2874099D4B79", 9, 0} =>
      {259_545_276, 2_845_669_466, 2_192_468_658},
    {:producer, "5333C7C3855A872BEF8F5812209D849A8336B78AB54D5A28AD298EF95107", 0, 0} =>
      {3_926_188_197, 4_134_984_520, 4_041_051_933},
    {:producer, "935E08BA5C0045A4CA47E23A4679ADCCC6FEB6B6A8A2E79E3032AC9DCF4E", 6, 2} =>
      {2_475_032_574, 514_922_479, 249_269_463},
    {:producer, "AFBBFA2030270377A2ECE63644380BEB3848C17B04B1DDFA7E4ACA98D62D", 2, 3} =>
      {1_959_123_733, 950_502_545, 982_835_446},
    {:producer, "935E08BA5C0045A4CA47E23A4679ADCCC6FEB6B6A8A2E79E3032AC9DCF4E", 3, 1} =>
      {493_078_382, 1_162_416_567, 542_428_380},
    {:consumer, "2E80B966016539ACAF3158608745EAF3869C02012C0B5FAB2874099D4B79", 1,
     "SimulatorGroup1", 1} => {3_780_820_911, 2_989_910_419, 1_017_180_885},
    {:consumer, "935E08BA5C0045A4CA47E23A4679ADCCC6FEB6B6A8A2E79E3032AC9DCF4E", 5,
     "SimulatorGroup1", 2} => {2_003_982_662, 899_308_854, 1_874_286_284},
    {:consumer, "A442D3AE8CE988D98E73856B9E7B947F906683D5D35BBF022257B2747C30", 5,
     "SimulatorGroup1", 2} => {930_997_959, 3_742_509_551, 1_732_558_329},
    {:producer, "BFBD0260BA02B81EFC02BF20D2ECDAEAA44490BD10F5744A0F5A3CB85CD2", 2, 1} =>
      {2_846_279_005, 1_072_890_824, 2_370_210_618},
    {:consumer, "2E80B966016539ACAF3158608745EAF3869C02012C0B5FAB2874099D4B79", 6,
     "SimulatorGroup1", 2} => {3_557_669_259, 1_059_376_015, 1_542_766_170},
    {:producer, "5333C7C3855A872BEF8F5812209D849A8336B78AB54D5A28AD298EF95107", 7, 1} =>
      {1_797_444_769, 3_684_220_316, 3_321_663_847},
    {:producer, "935E08BA5C0045A4CA47E23A4679ADCCC6FEB6B6A8A2E79E3032AC9DCF4E", 8, 6} =>
      {3_397_245_853, 204_826_442, 1_109_622_218},
    {:producer, "BFBD0260BA02B81EFC02BF20D2ECDAEAA44490BD10F5744A0F5A3CB85CD2", 0, 3} =>
      {1_353_943_274, 3_805_433_904, 1_308_397_011},
    {:producer, "2E80B966016539ACAF3158608745EAF3869C02012C0B5FAB2874099D4B79", 8, 1} =>
      {4_218_848_658, 1_342_146_053, 2_484_627_730},
    {:consumer, "BFBD0260BA02B81EFC02BF20D2ECDAEAA44490BD10F5744A0F5A3CB85CD2", 1,
     "SimulatorGroup1", 1} => {491_800_781, 2_718_633_659, 3_032_197_174},
    {:producer, "7EEAA041FCBFFCFB1DFE676EFA6CD64BC03784DF0C3326F1AB8451B97767", 2, 6} =>
      {485_068_335, 988_451_124, 2_548_705_763},
    {:consumer, "7EEAA041FCBFFCFB1DFE676EFA6CD64BC03784DF0C3326F1AB8451B97767", 2,
     "SimulatorGroup1", 2} => {2_051_042_620, 2_909_970_271, 3_977_707_165},
    {:producer, "A442D3AE8CE988D98E73856B9E7B947F906683D5D35BBF022257B2747C30", 2, 1} =>
      {1_801_507_008, 1_672_138_645, 3_862_113_582},
    {:producer, "2E80B966016539ACAF3158608745EAF3869C02012C0B5FAB2874099D4B79", 2, 7} =>
      {4_015_003_601, 1_088_688_111, 11_686_697},
    {:producer, "17A06A9E2B70472E0908AD7AA39C332653B51EB9D1FB9CAF59FCFAFF9AFE", 0, 4} =>
      {1_593_578_400, 2_038_414_163, 1_340_998_591},
    {:producer, "BFBD0260BA02B81EFC02BF20D2ECDAEAA44490BD10F5744A0F5A3CB85CD2", 0, 5} =>
      {1_258_773_352, 4_161_266_391, 4_190_970_514},
    {:producer, "A442D3AE8CE988D98E73856B9E7B947F906683D5D35BBF022257B2747C30", 2, 3} =>
      {2_339_397_990, 2_013_319_451, 2_905_106_235},
    {:consumer, "BFBD0260BA02B81EFC02BF20D2ECDAEAA44490BD10F5744A0F5A3CB85CD2", 3,
     "SimulatorGroup1", 1} => {3_128_127_022, 1_458_625_497, 687_436_948},
    {:producer, "7EEAA041FCBFFCFB1DFE676EFA6CD64BC03784DF0C3326F1AB8451B97767", 2, 5} =>
      {318_104_360, 887_384_328, 2_826_459_506},
    {:consumer, "5333C7C3855A872BEF8F5812209D849A8336B78AB54D5A28AD298EF95107", 3,
     "SimulatorGroup1", 2} => {3_603_992_442, 2_731_243_898, 1_591_594_692},
    {:producer, "2E80B966016539ACAF3158608745EAF3869C02012C0B5FAB2874099D4B79", 6, 1} =>
      {4_055_129_053, 307_273_230, 781_408_145},
    {:producer, "2E80B966016539ACAF3158608745EAF3869C02012C0B5FAB2874099D4B79", 0, 5} =>
      {3_600_945_537, 23_846_552, 2_418_655_229},
    {:producer, "7EEAA041FCBFFCFB1DFE676EFA6CD64BC03784DF0C3326F1AB8451B97767", 2, 1} =>
      {1_556_552_810, 498_939_747, 774_838_332},
    {:producer, "5333C7C3855A872BEF8F5812209D849A8336B78AB54D5A28AD298EF95107", 3, 3} =>
      {3_564_654_169, 20_716_923, 1_624_279_358},
    {:producer, "17A06A9E2B70472E0908AD7AA39C332653B51EB9D1FB9CAF59FCFAFF9AFE", 1, 1} =>
      {3_862_083_456, 1_549_033_824, 3_406_699_323},
    {:consumer, "5333C7C3855A872BEF8F5812209D849A8336B78AB54D5A28AD298EF95107", 2,
     "SimulatorGroup1", 0} => {238_950_623, 3_602_332_702, 374_769_622},
    {:producer, "935E08BA5C0045A4CA47E23A4679ADCCC6FEB6B6A8A2E79E3032AC9DCF4E", 5, 2} =>
      {657_065_616, 3_671_947_641, 2_698_962_833},
    {:producer, "5333C7C3855A872BEF8F5812209D849A8336B78AB54D5A28AD298EF95107", 6, 0} =>
      {3_923_485_604, 1_876_747_780, 1_884_708_823},
    {:producer, "17A06A9E2B70472E0908AD7AA39C332653B51EB9D1FB9CAF59FCFAFF9AFE", 2, 5} =>
      {4_231_711_695, 2_744_049_171, 3_820_807_815},
    {:consumer, "7EEAA041FCBFFCFB1DFE676EFA6CD64BC03784DF0C3326F1AB8451B97767", 0,
     "SimulatorGroup1", 2} => {4_032_474_405, 2_316_714_043, 3_649_571_781},
    {:producer, "935E08BA5C0045A4CA47E23A4679ADCCC6FEB6B6A8A2E79E3032AC9DCF4E", 4, 1} =>
      {238_348_748, 2_235_342_140, 3_570_891_397},
    {:producer, "AFBBFA2030270377A2ECE63644380BEB3848C17B04B1DDFA7E4ACA98D62D", 0, 1} =>
      {2_960_473_168, 714_859_257, 2_083_732_180},
    {:producer, "2E80B966016539ACAF3158608745EAF3869C02012C0B5FAB2874099D4B79", 2, 3} =>
      {168_741_083, 1_318_327_414, 1_474_908_338},
    {:producer, "AFBBFA2030270377A2ECE63644380BEB3848C17B04B1DDFA7E4ACA98D62D", 1, 3} =>
      {3_484_783_741, 1_140_481_617, 767_165_254},
    {:producer, "BFBD0260BA02B81EFC02BF20D2ECDAEAA44490BD10F5744A0F5A3CB85CD2", 1, 4} =>
      {2_509_871_739, 1_283_741_082, 157_965_304},
    {:consumer, "935E08BA5C0045A4CA47E23A4679ADCCC6FEB6B6A8A2E79E3032AC9DCF4E", 9,
     "SimulatorGroup1", 2} => {2_239_653_442, 1_654_610_337, 1_143_472_332},
    {:producer, "A442D3AE8CE988D98E73856B9E7B947F906683D5D35BBF022257B2747C30", 0, 4} =>
      {832_033_402, 3_109_190_571, 1_600_985_598},
    {:producer, "2E80B966016539ACAF3158608745EAF3869C02012C0B5FAB2874099D4B79", 2, 1} =>
      {3_237_724_055, 3_721_746_722, 3_414_237_255},
    {:producer, "935E08BA5C0045A4CA47E23A4679ADCCC6FEB6B6A8A2E79E3032AC9DCF4E", 3, 3} =>
      {3_307_613_715, 1_872_450_573, 933_656_704},
    {:producer, "BFBD0260BA02B81EFC02BF20D2ECDAEAA44490BD10F5744A0F5A3CB85CD2", 4, 2} =>
      {3_194_460_544, 4_006_831_766, 1_288_773_304},
    {:producer, "7EEAA041FCBFFCFB1DFE676EFA6CD64BC03784DF0C3326F1AB8451B97767", 0, 3} =>
      {2_546_752_277, 4_228_259_266, 893_147_304},
    {:consumer, "17A06A9E2B70472E0908AD7AA39C332653B51EB9D1FB9CAF59FCFAFF9AFE", 3,
     "SimulatorGroup1", 1} => {2_886_329_009, 3_822_934_947, 1_049_556_372},
    {:consumer, "7EEAA041FCBFFCFB1DFE676EFA6CD64BC03784DF0C3326F1AB8451B97767", 6,
     "SimulatorGroup1", 1} => {845_861_027, 1_589_742_110, 2_858_401_808},
    {:consumer, "A442D3AE8CE988D98E73856B9E7B947F906683D5D35BBF022257B2747C30", 0,
     "SimulatorGroup1", 1} => {2_771_503_643, 2_111_028_613, 3_012_005_223},
    {:producer, "2E80B966016539ACAF3158608745EAF3869C02012C0B5FAB2874099D4B79", 2, 0} =>
      {1_356_050_981, 4_207_670_853, 910_587_267},
    {:producer, "17A06A9E2B70472E0908AD7AA39C332653B51EB9D1FB9CAF59FCFAFF9AFE", 2, 1} =>
      {3_308_210_160, 2_028_429_608, 640_347_700},
    {:producer, "A442D3AE8CE988D98E73856B9E7B947F906683D5D35BBF022257B2747C30", 4, 4} =>
      {2_388_132_384, 2_160_730_770, 2_578_377_820},
    {:producer, "5333C7C3855A872BEF8F5812209D849A8336B78AB54D5A28AD298EF95107", 4, 0} =>
      {3_313_328_761, 2_342_341_124, 1_653_995_735},
    {:producer, "5333C7C3855A872BEF8F5812209D849A8336B78AB54D5A28AD298EF95107", 7, 3} =>
      {3_017_509_867, 129_175_432, 2_956_120_263},
    {:producer, "5333C7C3855A872BEF8F5812209D849A8336B78AB54D5A28AD298EF95107", 3, 5} =>
      {2_529_729_979, 3_699_185_618, 2_950_506_768},
    {:producer, "935E08BA5C0045A4CA47E23A4679ADCCC6FEB6B6A8A2E79E3032AC9DCF4E", 4, 3} =>
      {3_574_964_496, 1_815_042_205, 1_498_695_689},
    {:consumer, "7EEAA041FCBFFCFB1DFE676EFA6CD64BC03784DF0C3326F1AB8451B97767", 8,
     "SimulatorGroup1", 0} => {1_325_155_405, 4_103_132_720, 877_258_478},
    {:producer, "17A06A9E2B70472E0908AD7AA39C332653B51EB9D1FB9CAF59FCFAFF9AFE", 3, 1} =>
      {1_916_207_891, 1_746_687_016, 2_824_054_378},
    {:producer, "935E08BA5C0045A4CA47E23A4679ADCCC6FEB6B6A8A2E79E3032AC9DCF4E", 10, 6} =>
      {218_586_866, 2_460_441_722, 2_580_179_793},
    {:consumer, "935E08BA5C0045A4CA47E23A4679ADCCC6FEB6B6A8A2E79E3032AC9DCF4E", 3,
     "SimulatorGroup1", 0} => {2_772_196_836, 2_049_030_129, 3_120_749_673},
    {:producer, "7EEAA041FCBFFCFB1DFE676EFA6CD64BC03784DF0C3326F1AB8451B97767", 8, 5} =>
      {2_023_644_539, 1_804_649_216, 349_562_467},
    {:producer, "935E08BA5C0045A4CA47E23A4679ADCCC6FEB6B6A8A2E79E3032AC9DCF4E", 8, 2} =>
      {471_948_744, 878_897_006, 2_151_903_639},
    {:producer, "935E08BA5C0045A4CA47E23A4679ADCCC6FEB6B6A8A2E79E3032AC9DCF4E", 10, 0} =>
      {872_996_546, 2_039_981_501, 3_777_729_307},
    {:producer, "2E80B966016539ACAF3158608745EAF3869C02012C0B5FAB2874099D4B79", 3, 0} =>
      {3_879_253_564, 3_407_737_507, 645_338_837},
    {:producer, "AFBBFA2030270377A2ECE63644380BEB3848C17B04B1DDFA7E4ACA98D62D", 0, 4} =>
      {909_142_650, 1_704_303_313, 1_364_023_905},
    {:producer, "A442D3AE8CE988D98E73856B9E7B947F906683D5D35BBF022257B2747C30", 0, 3} =>
      {4_167_467_672, 2_243_350_005, 3_375_805_337},
    {:producer, "A442D3AE8CE988D98E73856B9E7B947F906683D5D35BBF022257B2747C30", 6, 7} =>
      {2_736_454_088, 2_105_648_995, 2_879_080_803},
    {:consumer, "935E08BA5C0045A4CA47E23A4679ADCCC6FEB6B6A8A2E79E3032AC9DCF4E", 3,
     "SimulatorGroup1", 1} => {2_467_257_004, 699_636_643, 2_883_584_121},
    {:producer, "935E08BA5C0045A4CA47E23A4679ADCCC6FEB6B6A8A2E79E3032AC9DCF4E", 1, 4} =>
      {668_315_789, 2_650_181_142, 31_078_033},
    {:producer, "BFBD0260BA02B81EFC02BF20D2ECDAEAA44490BD10F5744A0F5A3CB85CD2", 1, 5} =>
      {2_927_537_972, 1_395_459_441, 1_775_216_450},
    {:producer, "7EEAA041FCBFFCFB1DFE676EFA6CD64BC03784DF0C3326F1AB8451B97767", 5, 0} =>
      {3_871_504_330, 1_766_252_383, 3_976_080_397},
    {:producer, "A442D3AE8CE988D98E73856B9E7B947F906683D5D35BBF022257B2747C30", 6, 3} =>
      {1_351_550_514, 2_793_628_674, 924_059_736},
    {:producer, "2E80B966016539ACAF3158608745EAF3869C02012C0B5FAB2874099D4B79", 9, 1} =>
      {663_971_823, 2_684_937_004, 3_638_942_088},
    {:producer, "2E80B966016539ACAF3158608745EAF3869C02012C0B5FAB2874099D4B79", 7, 0} =>
      {3_926_487_309, 3_636_727_209, 1_067_158_328},
    {:consumer, "935E08BA5C0045A4CA47E23A4679ADCCC6FEB6B6A8A2E79E3032AC9DCF4E", 4,
     "SimulatorGroup1", 0} => {881_380_522, 2_608_385_817, 900_255_743},
    {:producer, "AFBBFA2030270377A2ECE63644380BEB3848C17B04B1DDFA7E4ACA98D62D", 0, 6} =>
      {3_740_405_836, 1_360_346_980, 2_117_656_924},
    {:producer, "AFBBFA2030270377A2ECE63644380BEB3848C17B04B1DDFA7E4ACA98D62D", 0, 5} =>
      {1_796_078_091, 2_307_018_413, 3_635_617_535},
    {:consumer, "5333C7C3855A872BEF8F5812209D849A8336B78AB54D5A28AD298EF95107", 6,
     "SimulatorGroup1", 2} => {1_772_206_231, 1_926_873_593, 1_955_477_153},
    {:consumer, "17A06A9E2B70472E0908AD7AA39C332653B51EB9D1FB9CAF59FCFAFF9AFE", 0,
     "SimulatorGroup1", 2} => {2_991_951_655, 175_132_622, 1_060_765_816},
    {:producer, "935E08BA5C0045A4CA47E23A4679ADCCC6FEB6B6A8A2E79E3032AC9DCF4E", 0, 7} =>
      {1_518_064_713, 3_086_222_246, 3_713_337_783},
    {:producer, "2E80B966016539ACAF3158608745EAF3869C02012C0B5FAB2874099D4B79", 9, 7} =>
      {1_462_525_444, 497_111_206, 1_787_898_498},
    {:producer, "A442D3AE8CE988D98E73856B9E7B947F906683D5D35BBF022257B2747C30", 3, 2} =>
      {3_575_280_392, 1_175_460_954, 2_806_446_217},
    {:producer, "2E80B966016539ACAF3158608745EAF3869C02012C0B5FAB2874099D4B79", 4, 1} =>
      {3_535_695_466, 2_386_845_318, 689_028_302},
    {:producer, "2E80B966016539ACAF3158608745EAF3869C02012C0B5FAB2874099D4B79", 1, 0} =>
      {2_454_538_208, 354_955_700, 2_063_527_588},
    {:consumer, "935E08BA5C0045A4CA47E23A4679ADCCC6FEB6B6A8A2E79E3032AC9DCF4E", 8,
     "SimulatorGroup1", 0} => {834_454_027, 3_954_825_136, 1_583_213_793},
    {:consumer, "7EEAA041FCBFFCFB1DFE676EFA6CD64BC03784DF0C3326F1AB8451B97767", 3,
     "SimulatorGroup1", 2} => {2_319_736_335, 3_425_137_077, 3_540_807_868},
    {:producer, "5333C7C3855A872BEF8F5812209D849A8336B78AB54D5A28AD298EF95107", 5, 1} =>
      {1_560_578_872, 2_237_107_174, 4_215_812_819},
    {:producer, "17A06A9E2B70472E0908AD7AA39C332653B51EB9D1FB9CAF59FCFAFF9AFE", 0, 6} =>
      {2_101_627_827, 479_016_166, 1_035_112_994},
    {:producer, "AFBBFA2030270377A2ECE63644380BEB3848C17B04B1DDFA7E4ACA98D62D", 2, 4} =>
      {2_130_711_796, 3_685_849_977, 2_237_951_809},
    {:consumer, "2E80B966016539ACAF3158608745EAF3869C02012C0B5FAB2874099D4B79", 0,
     "SimulatorGroup1", 0} => {509_255_020, 3_617_166_549, 522_659_625},
    {:producer, "7EEAA041FCBFFCFB1DFE676EFA6CD64BC03784DF0C3326F1AB8451B97767", 0, 2} =>
      {1_282_331_171, 1_681_124_715, 1_906_108_461},
    {:producer, "17A06A9E2B70472E0908AD7AA39C332653B51EB9D1FB9CAF59FCFAFF9AFE", 2, 3} =>
      {3_285_951_755, 3_867_537_917, 1_208_071_571},
    {:consumer, "A442D3AE8CE988D98E73856B9E7B947F906683D5D35BBF022257B2747C30", 1,
     "SimulatorGroup1", 0} => {1_511_374_068, 695_674_513, 2_820_497_816},
    {:producer, "7EEAA041FCBFFCFB1DFE676EFA6CD64BC03784DF0C3326F1AB8451B97767", 7, 5} =>
      {1_187_783_970, 1_642_748_854, 625_376_226},
    {:producer, "2E80B966016539ACAF3158608745EAF3869C02012C0B5FAB2874099D4B79", 0, 6} =>
      {4_146_568_148, 2_208_061_307, 2_343_541_127},
    {:consumer, "2E80B966016539ACAF3158608745EAF3869C02012C0B5FAB2874099D4B79", 2,
     "SimulatorGroup1", 1} => {1_776_805_806, 505_209_174, 2_442_723_993},
    {:producer, "7EEAA041FCBFFCFB1DFE676EFA6CD64BC03784DF0C3326F1AB8451B97767", 3, 7} =>
      {1_793_296_206, 3_462_483_988, 1_577_190_618},
    {:producer, "7EEAA041FCBFFCFB1DFE676EFA6CD64BC03784DF0C3326F1AB8451B97767", 9, 0} =>
      {3_171_287_942, 2_530_759_547, 3_222_170_521},
    {:producer, "AFBBFA2030270377A2ECE63644380BEB3848C17B04B1DDFA7E4ACA98D62D", 2, 7} =>
      {3_145_847_694, 1_581_503_439, 1_799_973_112},
    {:producer, "935E08BA5C0045A4CA47E23A4679ADCCC6FEB6B6A8A2E79E3032AC9DCF4E", 5, 6} =>
      {4_268_050_672, 4_029_594_858, 1_544_372_301},
    {:producer, "935E08BA5C0045A4CA47E23A4679ADCCC6FEB6B6A8A2E79E3032AC9DCF4E", 2, 7} =>
      {2_254_804_618, 3_319_169_554, 2_405_300_711},
    {:producer, "7EEAA041FCBFFCFB1DFE676EFA6CD64BC03784DF0C3326F1AB8451B97767", 10, 2} =>
      {3_492_313_153, 2_810_172_399, 2_852_402_876},
    {:producer, "A442D3AE8CE988D98E73856B9E7B947F906683D5D35BBF022257B2747C30", 2, 6} =>
      {3_026_249_507, 1_645_749_753, 34_439_258},
    {:producer, "17A06A9E2B70472E0908AD7AA39C332653B51EB9D1FB9CAF59FCFAFF9AFE", 1, 6} =>
      {2_287_543_562, 4_182_623_618, 1_569_496_474},
    {:producer, "2E80B966016539ACAF3158608745EAF3869C02012C0B5FAB2874099D4B79", 1, 4} =>
      {3_844_107_125, 826_259_956, 1_151_896_764},
    {:producer, "935E08BA5C0045A4CA47E23A4679ADCCC6FEB6B6A8A2E79E3032AC9DCF4E", 9, 0} =>
      {569_128_151, 1_910_679_380, 4_261_022_172},
    {:producer, "7EEAA041FCBFFCFB1DFE676EFA6CD64BC03784DF0C3326F1AB8451B97767", 9, 5} =>
      {1_041_779_863, 3_255_039_431, 2_955_705_885},
    {:consumer, "7EEAA041FCBFFCFB1DFE676EFA6CD64BC03784DF0C3326F1AB8451B97767", 8,
     "SimulatorGroup1", 2} => {2_172_922_068, 3_722_897_453, 4_022_370_134},
    {:consumer, "935E08BA5C0045A4CA47E23A4679ADCCC6FEB6B6A8A2E79E3032AC9DCF4E", 7,
     "SimulatorGroup1", 2} => {1_085_140_013, 1_538_626_874, 178_558_518},
    {:producer, "2E80B966016539ACAF3158608745EAF3869C02012C0B5FAB2874099D4B79", 9, 2} =>
      {1_950_688_479, 2_407_864_965, 1_940_783_038},
    {:consumer, "BFBD0260BA02B81EFC02BF20D2ECDAEAA44490BD10F5744A0F5A3CB85CD2", 0,
     "SimulatorGroup1", 1} => {4_255_049_902, 1_509_170_627, 1_845_816_672},
    {:producer, "17A06A9E2B70472E0908AD7AA39C332653B51EB9D1FB9CAF59FCFAFF9AFE", 3, 0} =>
      {2_950_284_913, 2_244_973_929, 1_666_466_913},
    {:producer, "17A06A9E2B70472E0908AD7AA39C332653B51EB9D1FB9CAF59FCFAFF9AFE", 2, 6} =>
      {2_168_854_526, 454_578_437, 1_245_362_132},
    {:consumer, "7EEAA041FCBFFCFB1DFE676EFA6CD64BC03784DF0C3326F1AB8451B97767", 2,
     "SimulatorGroup1", 0} => {1_196_422_494, 2_165_303_005, 2_108_436_013},
    {:consumer, "A442D3AE8CE988D98E73856B9E7B947F906683D5D35BBF022257B2747C30", 4,
     "SimulatorGroup1", 1} => {1_676_986_695, 1_527_592_555, 883_030_568},
    {:producer, "2E80B966016539ACAF3158608745EAF3869C02012C0B5FAB2874099D4B79", 3, 1} =>
      {120_948_427, 510_533_219, 3_260_288_014},
    {:consumer, "2E80B966016539ACAF3158608745EAF3869C02012C0B5FAB2874099D4B79", 8,
     "SimulatorGroup1", 0} => {2_100_123_549, 1_046_256_416, 316_641_456},
    {:producer, "7EEAA041FCBFFCFB1DFE676EFA6CD64BC03784DF0C3326F1AB8451B97767", 11, 3} =>
      {61_308_695, 88_921_912, 2_455_364_787},
    {:producer, "7EEAA041FCBFFCFB1DFE676EFA6CD64BC03784DF0C3326F1AB8451B97767", 8, 3} =>
      {149_000_511, 3_105_710_962, 3_299_480_331},
    {:consumer, "AFBBFA2030270377A2ECE63644380BEB3848C17B04B1DDFA7E4ACA98D62D", 0,
     "SimulatorGroup1", 0} => {4_105_707_437, 2_789_089_707, 977_408_231},
    {:producer, "935E08BA5C0045A4CA47E23A4679ADCCC6FEB6B6A8A2E79E3032AC9DCF4E", 9, 4} =>
      {3_710_192_391, 235_750_613, 1_728_568_043},
    {:producer, "7EEAA041FCBFFCFB1DFE676EFA6CD64BC03784DF0C3326F1AB8451B97767", 7, 0} =>
      {1_407_462_887, 2_813_755_581, 3_727_488_880},
    {:producer, "5333C7C3855A872BEF8F5812209D849A8336B78AB54D5A28AD298EF95107", 3, 4} =>
      {1_499_368_229, 571_759_039, 1_394_985_724},
    {:producer, "935E08BA5C0045A4CA47E23A4679ADCCC6FEB6B6A8A2E79E3032AC9DCF4E", 9, 1} =>
      {2_708_247_074, 422_873_746, 3_190_997_999},
    {:producer, "AFBBFA2030270377A2ECE63644380BEB3848C17B04B1DDFA7E4ACA98D62D", 1, 0} =>
      {3_712_095_588, 3_612_310_507, 1_212_418_972},
    {:consumer, "7EEAA041FCBFFCFB1DFE676EFA6CD64BC03784DF0C3326F1AB8451B97767", 7,
     "SimulatorGroup1", 1} => {2_829_272_417, 785_705_693, 1_916_888_969},
    {:producer, "BFBD0260BA02B81EFC02BF20D2ECDAEAA44490BD10F5744A0F5A3CB85CD2", 2, 7} =>
      {1_569_532_779, 4_211_114_380, 1_761_737_615},
    {:producer, "2E80B966016539ACAF3158608745EAF3869C02012C0B5FAB2874099D4B79", 7, 4} =>
      {2_825_939_957, 2_256_762_235, 2_638_174_516},
    {:producer, "17A06A9E2B70472E0908AD7AA39C332653B51EB9D1FB9CAF59FCFAFF9AFE", 1, 4} =>
      {4_214_934_730, 2_308_827_686, 2_939_686_734},
    {:producer, "7EEAA041FCBFFCFB1DFE676EFA6CD64BC03784DF0C3326F1AB8451B97767", 7, 6} =>
      {2_195_067_173, 3_399_912_363, 486_482_833},
    {:consumer, "2E80B966016539ACAF3158608745EAF3869C02012C0B5FAB2874099D4B79", 2,
     "SimulatorGroup1", 0} => {4_038_089_949, 3_131_511_054, 1_711_449_721},
    {:consumer, "17A06A9E2B70472E0908AD7AA39C332653B51EB9D1FB9CAF59FCFAFF9AFE", 2,
     "SimulatorGroup1", 2} => {95_769_146, 2_794_916_882, 1_948_877_219},
    {:producer, "935E08BA5C0045A4CA47E23A4679ADCCC6FEB6B6A8A2E79E3032AC9DCF4E", 6, 0} =>
      {1_052_270_410, 359_298_129, 2_963_273_515},
    {:consumer, "A442D3AE8CE988D98E73856B9E7B947F906683D5D35BBF022257B2747C30", 6,
     "SimulatorGroup1", 0} => {928_590_900, 4_048_093_937, 3_383_559_516},
    {:producer, "7EEAA041FCBFFCFB1DFE676EFA6CD64BC03784DF0C3326F1AB8451B97767", 4, 3} =>
      {2_917_687_045, 2_011_667_270, 2_828_146_871},
    {:consumer, "935E08BA5C0045A4CA47E23A4679ADCCC6FEB6B6A8A2E79E3032AC9DCF4E", 1,
     "SimulatorGroup1", 0} => {3_725_983_767, 1_930_786_440, 2_270_379_420},
    {:producer, "935E08BA5C0045A4CA47E23A4679ADCCC6FEB6B6A8A2E79E3032AC9DCF4E", 5, 1} =>
      {2_746_362_350, 3_273_159_569, 3_908_142_050},
    {:consumer, "7EEAA041FCBFFCFB1DFE676EFA6CD64BC03784DF0C3326F1AB8451B97767", 0,
     "SimulatorGroup1", 0} => {2_136_002_538, 2_670_464_316, 4_181_808_628},
    {:producer, "5333C7C3855A872BEF8F5812209D849A8336B78AB54D5A28AD298EF95107", 2, 7} =>
      {895_961_663, 1_808_134_686, 2_482_385_880},
    {:consumer, "17A06A9E2B70472E0908AD7AA39C332653B51EB9D1FB9CAF59FCFAFF9AFE", 1,
     "SimulatorGroup1", 0} => {3_736_864_883, 290_737_261, 662_366_897},
    {:consumer, "AFBBFA2030270377A2ECE63644380BEB3848C17B04B1DDFA7E4ACA98D62D", 2,
     "SimulatorGroup1", 1} => {741_990_150, 3_051_027_208, 3_960_812_991},
    {:producer, "5333C7C3855A872BEF8F5812209D849A8336B78AB54D5A28AD298EF95107", 4, 2} =>
      {469_701_175, 844_907_138, 1_515_135_361},
    {:consumer, "BFBD0260BA02B81EFC02BF20D2ECDAEAA44490BD10F5744A0F5A3CB85CD2", 2,
     "SimulatorGroup1", 2} => {887_615_127, 1_481_956_877, 4_019_879_619},
    {:producer, "935E08BA5C0045A4CA47E23A4679ADCCC6FEB6B6A8A2E79E3032AC9DCF4E", 2, 2} =>
      {131_537_426, 3_143_918_391, 1_068_272_268},
    {:consumer, "935E08BA5C0045A4CA47E23A4679ADCCC6FEB6B6A8A2E79E3032AC9DCF4E", 7,
     "SimulatorGroup1", 0} => {3_706_583_148, 430_946_820, 651_178_126},
    {:producer, "7EEAA041FCBFFCFB1DFE676EFA6CD64BC03784DF0C3326F1AB8451B97767", 4, 7} =>
      {2_103_589_679, 3_134_879_168, 2_523_683_009},
    {:producer, "935E08BA5C0045A4CA47E23A4679ADCCC6FEB6B6A8A2E79E3032AC9DCF4E", 2, 6} =>
      {2_127_948_185, 3_699_257_491, 3_404_517_084},
    {:producer, "7EEAA041FCBFFCFB1DFE676EFA6CD64BC03784DF0C3326F1AB8451B97767", 7, 1} =>
      {2_164_829_461, 1_014_741_050, 1_630_907_997},
    {:consumer, "AFBBFA2030270377A2ECE63644380BEB3848C17B04B1DDFA7E4ACA98D62D", 0,
     "SimulatorGroup1", 2} => {751_614_625, 2_163_685_786, 1_210_536_333},
    {:producer, "935E08BA5C0045A4CA47E23A4679ADCCC6FEB6B6A8A2E79E3032AC9DCF4E", 0, 6} =>
      {402_346_305, 1_596_014_123, 986_390_141},
    {:producer, "7EEAA041FCBFFCFB1DFE676EFA6CD64BC03784DF0C3326F1AB8451B97767", 5, 5} =>
      {3_156_443_826, 306_176_062, 4_125_941_770},
    {:producer, "935E08BA5C0045A4CA47E23A4679ADCCC6FEB6B6A8A2E79E3032AC9DCF4E", 8, 3} =>
      {3_397_404_367, 2_242_397_260, 2_912_764_799},
    {:producer, "2E80B966016539ACAF3158608745EAF3869C02012C0B5FAB2874099D4B79", 9, 6} =>
      {2_973_731_768, 3_310_142_306, 3_034_970_998},
    {:producer, "2E80B966016539ACAF3158608745EAF3869C02012C0B5FAB2874099D4B79", 0, 1} =>
      {159_207_002, 867_036_128, 140_666_784},
    {:consumer, "2E80B966016539ACAF3158608745EAF3869C02012C0B5FAB2874099D4B79", 8,
     "SimulatorGroup1", 2} => {251_999_647, 4_201_898_648, 841_149_831},
    {:producer, "5333C7C3855A872BEF8F5812209D849A8336B78AB54D5A28AD298EF95107", 2, 3} =>
      {38_409_135, 2_138_216_515, 2_615_337_513},
    {:producer, "2E80B966016539ACAF3158608745EAF3869C02012C0B5FAB2874099D4B79", 7, 2} =>
      {661_008_861, 3_847_477_315, 3_684_186_588},
    {:producer, "7EEAA041FCBFFCFB1DFE676EFA6CD64BC03784DF0C3326F1AB8451B97767", 2, 2} =>
      {505_587_925, 2_660_901_710, 3_373_852_991},
    {:producer, "5333C7C3855A872BEF8F5812209D849A8336B78AB54D5A28AD298EF95107", 0, 7} =>
      {1_529_266_835, 2_771_956_048, 2_381_920_123},
    {:consumer, "2E80B966016539ACAF3158608745EAF3869C02012C0B5FAB2874099D4B79", 4,
     "SimulatorGroup1", 2} => {3_489_111_303, 1_954_935_209, 3_001_242_175},
    {:producer, "5333C7C3855A872BEF8F5812209D849A8336B78AB54D5A28AD298EF95107", 2, 2} =>
      {1_954_911_437, 844_342_557, 1_116_299_901},
    {:producer, "7EEAA041FCBFFCFB1DFE676EFA6CD64BC03784DF0C3326F1AB8451B97767", 11, 0} =>
      {4_172_841_127, 2_628_227_371, 1_296_338_991},
    {:producer, "BFBD0260BA02B81EFC02BF20D2ECDAEAA44490BD10F5744A0F5A3CB85CD2", 2, 6} =>
      {1_500_132_108, 3_139_652_093, 968_727_369},
    {:consumer, "BFBD0260BA02B81EFC02BF20D2ECDAEAA44490BD10F5744A0F5A3CB85CD2", 1,
     "SimulatorGroup1", 0} => {2_249_133_423, 2_601_909_956, 2_268_012_171},
    {:producer, "BFBD0260BA02B81EFC02BF20D2ECDAEAA44490BD10F5744A0F5A3CB85CD2", 3, 1} =>
      {1_140_625_048, 2_396_611_263, 649_497_740},
    {:consumer, "7EEAA041FCBFFCFB1DFE676EFA6CD64BC03784DF0C3326F1AB8451B97767", 5,
     "SimulatorGroup1", 1} => {1_254_710_059, 2_903_504_296, 907_288_604},
    {:consumer, "BFBD0260BA02B81EFC02BF20D2ECDAEAA44490BD10F5744A0F5A3CB85CD2", 4,
     "SimulatorGroup1", 0} => {2_202_410_955, 2_367_136_277, 2_267_942_381},
    {:producer, "7EEAA041FCBFFCFB1DFE676EFA6CD64BC03784DF0C3326F1AB8451B97767", 7, 7} =>
      {205_495_799, 34_624_622, 1_760_173_773},
    {:producer, "7EEAA041FCBFFCFB1DFE676EFA6CD64BC03784DF0C3326F1AB8451B97767", 3, 0} =>
      {329_483_939, 3_994_331_733, 207_164_472},
    {:producer, "7EEAA041FCBFFCFB1DFE676EFA6CD64BC03784DF0C3326F1AB8451B97767", 9, 3} =>
      {4_054_993_497, 1_060_395_848, 2_949_085_909},
    {:producer, "5333C7C3855A872BEF8F5812209D849A8336B78AB54D5A28AD298EF95107", 1, 2} =>
      {4_184_189_553, 4_196_099_070, 1_392_319_840},
    {:consumer, "A442D3AE8CE988D98E73856B9E7B947F906683D5D35BBF022257B2747C30", 5,
     "SimulatorGroup1", 0} => {3_164_089_462, 3_143_234_679, 1_418_014_207},
    {:producer, "7EEAA041FCBFFCFB1DFE676EFA6CD64BC03784DF0C3326F1AB8451B97767", 4, 1} =>
      {3_597_208_845, 28_984_632, 509_371_057},
    {:consumer, "7EEAA041FCBFFCFB1DFE676EFA6CD64BC03784DF0C3326F1AB8451B97767", 4,
     "SimulatorGroup1", 2} => {3_100_497_727, 1_799_232_317, 3_786_013_583},
    {:consumer, "7EEAA041FCBFFCFB1DFE676EFA6CD64BC03784DF0C3326F1AB8451B97767", 3,
     "SimulatorGroup1", 0} => {3_933_642_984, 3_720_416_802, 1_845_217_088},
    {:consumer, "BFBD0260BA02B81EFC02BF20D2ECDAEAA44490BD10F5744A0F5A3CB85CD2", 2,
     "SimulatorGroup1", 0} => {2_593_846_661, 2_364_053_331, 4_034_429_493},
    {:producer, "2E80B966016539ACAF3158608745EAF3869C02012C0B5FAB2874099D4B79", 7, 6} =>
      {843_457_833, 2_874_885_697, 618_245_588},
    {:producer, "5333C7C3855A872BEF8F5812209D849A8336B78AB54D5A28AD298EF95107", 6, 2} =>
      {2_837_127_302, 2_329_028_637, 1_350_960_574},
    {:producer, "17A06A9E2B70472E0908AD7AA39C332653B51EB9D1FB9CAF59FCFAFF9AFE", 3, 5} =>
      {3_287_598_489, 639_542_008, 60_131_300},
    {:producer, "935E08BA5C0045A4CA47E23A4679ADCCC6FEB6B6A8A2E79E3032AC9DCF4E", 0, 4} =>
      {2_875_825_764, 1_070_326_142, 3_417_558_997},
    {:consumer, "A442D3AE8CE988D98E73856B9E7B947F906683D5D35BBF022257B2747C30", 1,
     "SimulatorGroup1", 2} => {1_510_973_235, 2_518_601_587, 14_031_870},
    {:consumer, "2E80B966016539ACAF3158608745EAF3869C02012C0B5FAB2874099D4B79", 5,
     "SimulatorGroup1", 0} => {3_828_799_779, 691_667_402, 1_185_991_537},
    {:producer, "5333C7C3855A872BEF8F5812209D849A8336B78AB54D5A28AD298EF95107", 5, 2} =>
      {3_047_658_270, 3_739_953_128, 2_779_044_508},
    {:producer, "5333C7C3855A872BEF8F5812209D849A8336B78AB54D5A28AD298EF95107", 2, 0} =>
      {671_842_515, 3_087_857_699, 2_969_280_865},
    {:producer, "935E08BA5C0045A4CA47E23A4679ADCCC6FEB6B6A8A2E79E3032AC9DCF4E", 10, 1} =>
      {945_107_767, 790_428_444, 1_407_333_049},
    {:producer, "AFBBFA2030270377A2ECE63644380BEB3848C17B04B1DDFA7E4ACA98D62D", 2, 5} =>
      {1_125_353_280, 780_967_486, 1_496_946_259},
    {:producer, "BFBD0260BA02B81EFC02BF20D2ECDAEAA44490BD10F5744A0F5A3CB85CD2", 4, 3} =>
      {3_938_069_716, 3_422_129_171, 3_862_160_597},
    {:producer, "2E80B966016539ACAF3158608745EAF3869C02012C0B5FAB2874099D4B79", 3, 6} =>
      {752_911_010, 1_875_692_452, 3_442_643_278},
    {:consumer, "2E80B966016539ACAF3158608745EAF3869C02012C0B5FAB2874099D4B79", 0,
     "SimulatorGroup1", 1} => {737_664_773, 3_198_377_627, 1_096_139_867},
    {:producer, "BFBD0260BA02B81EFC02BF20D2ECDAEAA44490BD10F5744A0F5A3CB85CD2", 3, 2} =>
      {487_310_947, 786_469_457, 3_241_329_588},
    {:consumer, "2E80B966016539ACAF3158608745EAF3869C02012C0B5FAB2874099D4B79", 1,
     "SimulatorGroup1", 0} => {2_514_250_623, 2_267_114_957, 1_117_274_961},
    {:consumer, "2E80B966016539ACAF3158608745EAF3869C02012C0B5FAB2874099D4B79", 9,
     "SimulatorGroup1", 1} => {381_740_565, 3_961_204_090, 3_020_935_321},
    {:producer, "BFBD0260BA02B81EFC02BF20D2ECDAEAA44490BD10F5744A0F5A3CB85CD2", 0, 6} =>
      {3_442_450_433, 2_479_073_590, 3_198_670_792},
    {:producer, "A442D3AE8CE988D98E73856B9E7B947F906683D5D35BBF022257B2747C30", 0, 1} =>
      {4_072_184_909, 1_255_792_403, 3_043_570_507},
    {:producer, "935E08BA5C0045A4CA47E23A4679ADCCC6FEB6B6A8A2E79E3032AC9DCF4E", 10, 4} =>
      {2_188_080_489, 2_577_303_603, 1_406_580_095},
    {:consumer, "935E08BA5C0045A4CA47E23A4679ADCCC6FEB6B6A8A2E79E3032AC9DCF4E", 7,
     "SimulatorGroup1", 1} => {1_823_738_339, 3_539_700_526, 1_583_379_512},
    {:producer, "BFBD0260BA02B81EFC02BF20D2ECDAEAA44490BD10F5744A0F5A3CB85CD2", 1, 7} =>
      {672_530_230, 3_747_005_900, 1_682_869_391},
    {:producer, "2E80B966016539ACAF3158608745EAF3869C02012C0B5FAB2874099D4B79", 0, 7} =>
      {2_806_912_070, 3_989_586_881, 1_998_974_899},
    {:producer, "17A06A9E2B70472E0908AD7AA39C332653B51EB9D1FB9CAF59FCFAFF9AFE", 3, 6} =>
      {904_100_373, 3_383_467_728, 1_242_167_968},
    {:producer, "BFBD0260BA02B81EFC02BF20D2ECDAEAA44490BD10F5744A0F5A3CB85CD2", 3, 6} =>
      {3_940_942_723, 3_597_918_062, 2_461_712_107},
    {:producer, "935E08BA5C0045A4CA47E23A4679ADCCC6FEB6B6A8A2E79E3032AC9DCF4E", 3, 5} =>
      {3_061_141_197, 789_764_900, 4_131_623_936},
    {:producer, "7EEAA041FCBFFCFB1DFE676EFA6CD64BC03784DF0C3326F1AB8451B97767", 5, 6} =>
      {22_505_449, 3_624_832_071, 3_280_409_047},
    {:consumer, "2E80B966016539ACAF3158608745EAF3869C02012C0B5FAB2874099D4B79", 3,
     "SimulatorGroup1", 1} => {1_586_339_788, 754_440_575, 3_332_735_281},
    {:consumer, "BFBD0260BA02B81EFC02BF20D2ECDAEAA44490BD10F5744A0F5A3CB85CD2", 0,
     "SimulatorGroup1", 2} => {2_769_187_897, 1_207_930_927, 1_613_597_845},
    {:producer, "BFBD0260BA02B81EFC02BF20D2ECDAEAA44490BD10F5744A0F5A3CB85CD2", 4, 6} =>
      {1_632_619_132, 1_902_175_704, 1_526_128_602},
    {:consumer, "2E80B966016539ACAF3158608745EAF3869C02012C0B5FAB2874099D4B79", 7,
     "SimulatorGroup1", 1} => {3_110_564_533, 3_088_456_205, 3_568_682_972},
    {:producer, "A442D3AE8CE988D98E73856B9E7B947F906683D5D35BBF022257B2747C30", 4, 1} =>
      {1_936_681_882, 4_163_429_216, 2_766_096_396},
    {:producer, "A442D3AE8CE988D98E73856B9E7B947F906683D5D35BBF022257B2747C30", 3, 7} =>
      {2_667_595_163, 3_582_823_496, 3_967_340_074},
    {:producer, "7EEAA041FCBFFCFB1DFE676EFA6CD64BC03784DF0C3326F1AB8451B97767", 3, 3} =>
      {1_600_796_828, 1_396_259_010, 94_635_360},
    {:producer, "A442D3AE8CE988D98E73856B9E7B947F906683D5D35BBF022257B2747C30", 1, 2} =>
      {2_125_257_950, 2_941_356_104, 2_145_126_434},
    {:consumer, "A442D3AE8CE988D98E73856B9E7B947F906683D5D35BBF022257B2747C30", 4,
     "SimulatorGroup1", 2} => {2_550_433_762, 759_438_488, 3_809_897_609},
    {:producer, "7EEAA041FCBFFCFB1DFE676EFA6CD64BC03784DF0C3326F1AB8451B97767", 9, 1} =>
      {1_508_318_635, 2_361_558_589, 2_472_864_107},
    {:producer, "2E80B966016539ACAF3158608745EAF3869C02012C0B5FAB2874099D4B79", 1, 7} =>
      {877_508_321, 727_667_505, 2_695_899_240},
    {:producer, "A442D3AE8CE988D98E73856B9E7B947F906683D5D35BBF022257B2747C30", 6, 1} =>
      {1_511_337_875, 2_883_336_409, 738_150_671},
    {:consumer, "5333C7C3855A872BEF8F5812209D849A8336B78AB54D5A28AD298EF95107", 5,
     "SimulatorGroup1", 2} => {2_756_970_453, 4_225_619_583, 1_250_439_515},
    {:producer, "A442D3AE8CE988D98E73856B9E7B947F906683D5D35BBF022257B2747C30", 2, 5} =>
      {2_555_408_200, 1_601_896_955, 1_369_426_264},
    {:consumer, "7EEAA041FCBFFCFB1DFE676EFA6CD64BC03784DF0C3326F1AB8451B97767", 9,
     "SimulatorGroup1", 2} => {692_020_201, 2_230_727_888, 577_195_377},
    {:producer, "935E08BA5C0045A4CA47E23A4679ADCCC6FEB6B6A8A2E79E3032AC9DCF4E", 0, 1} =>
      {895_802_150, 3_785_281_015, 983_121_282},
    {:producer, "5333C7C3855A872BEF8F5812209D849A8336B78AB54D5A28AD298EF95107", 2, 1} =>
      {1_648_578_633, 662_377_374, 4_003_148_784},
    {:producer, "935E08BA5C0045A4CA47E23A4679ADCCC6FEB6B6A8A2E79E3032AC9DCF4E", 5, 5} =>
      {3_724_916_027, 2_220_017_444, 266_543_854},
    {:consumer, "2E80B966016539ACAF3158608745EAF3869C02012C0B5FAB2874099D4B79", 6,
     "SimulatorGroup1", 1} => {2_548_113_471, 1_249_480_967, 1_944_240_558},
    {:consumer, "5333C7C3855A872BEF8F5812209D849A8336B78AB54D5A28AD298EF95107", 2,
     "SimulatorGroup1", 2} => {3_417_920_598, 2_701_559_708, 494_051_200},
    {:producer, "7EEAA041FCBFFCFB1DFE676EFA6CD64BC03784DF0C3326F1AB8451B97767", 8, 4} =>
      {2_069_585_921, 380_620_542, 17_778_324},
    {:producer, "2E80B966016539ACAF3158608745EAF3869C02012C0B5FAB2874099D4B79", 5, 3} =>
      {758_498_646, 4_028_304_876, 1_053_052_730},
    {:producer, "935E08BA5C0045A4CA47E23A4679ADCCC6FEB6B6A8A2E79E3032AC9DCF4E", 10, 3} =>
      {2_228_360_137, 1_434_426_100, 235_481_601},
    {:producer, "7EEAA041FCBFFCFB1DFE676EFA6CD64BC03784DF0C3326F1AB8451B97767", 4, 5} =>
      {453_820_527, 2_009_572_184, 2_820_171_813},
    {:producer, "A442D3AE8CE988D98E73856B9E7B947F906683D5D35BBF022257B2747C30", 2, 4} =>
      {640_918_132, 4_197_140_258, 1_032_648_161},
    {:producer, "7EEAA041FCBFFCFB1DFE676EFA6CD64BC03784DF0C3326F1AB8451B97767", 5, 3} =>
      {4_256_621_447, 678_382_985, 1_188_005_135},
    {:producer, "7EEAA041FCBFFCFB1DFE676EFA6CD64BC03784DF0C3326F1AB8451B97767", 3, 4} =>
      {1_887_202_916, 2_115_663_806, 318_348_374},
    {:producer, "5333C7C3855A872BEF8F5812209D849A8336B78AB54D5A28AD298EF95107", 1, 4} =>
      {2_250_164_593, 3_379_043_784, 395_936_786},
    {:producer, "A442D3AE8CE988D98E73856B9E7B947F906683D5D35BBF022257B2747C30", 5, 4} =>
      {772_718_322, 215_142_648, 4_045_636_693},
    {:producer, "935E08BA5C0045A4CA47E23A4679ADCCC6FEB6B6A8A2E79E3032AC9DCF4E", 5, 4} =>
      {2_454_306_032, 3_416_708_569, 1_451_174_802},
    {:producer, "2E80B966016539ACAF3158608745EAF3869C02012C0B5FAB2874099D4B79", 2, 5} =>
      {3_287_043_406, 4_016_504_956, 1_314_493_967},
    {:producer, "7EEAA041FCBFFCFB1DFE676EFA6CD64BC03784DF0C3326F1AB8451B97767", 0, 0} =>
      {2_491_594_207, 3_248_390_748, 3_511_025_995},
    {:producer, "7EEAA041FCBFFCFB1DFE676EFA6CD64BC03784DF0C3326F1AB8451B97767", 1, 4} =>
      {2_964_645_881, 4_008_193_801, 2_437_150_703},
    {:consumer, "935E08BA5C0045A4CA47E23A4679ADCCC6FEB6B6A8A2E79E3032AC9DCF4E", 6,
     "SimulatorGroup1", 0} => {3_559_919_521, 2_559_228_558, 2_583_592_969},
    {:producer, "7EEAA041FCBFFCFB1DFE676EFA6CD64BC03784DF0C3326F1AB8451B97767", 6, 5} =>
      {3_133_001_946, 889_619_795, 160_267_276},
    {:producer, "BFBD0260BA02B81EFC02BF20D2ECDAEAA44490BD10F5744A0F5A3CB85CD2", 0, 4} =>
      {3_093_459_143, 2_047_435_625, 3_208_938_580},
    {:producer, "7EEAA041FCBFFCFB1DFE676EFA6CD64BC03784DF0C3326F1AB8451B97767", 1, 1} =>
      {2_695_595_566, 3_990_280_967, 4_076_638_373},
    {:producer, "935E08BA5C0045A4CA47E23A4679ADCCC6FEB6B6A8A2E79E3032AC9DCF4E", 8, 5} =>
      {3_181_897_998, 2_759_062_673, 3_761_098_296},
    {:consumer, "BFBD0260BA02B81EFC02BF20D2ECDAEAA44490BD10F5744A0F5A3CB85CD2", 2,
     "SimulatorGroup1", 1} => {1_745_038_434, 3_578_344_952, 1_994_772_327},
    {:producer, "935E08BA5C0045A4CA47E23A4679ADCCC6FEB6B6A8A2E79E3032AC9DCF4E", 10, 5} =>
      {2_703_426_851, 864_610_936, 415_066_588},
    {:producer, "935E08BA5C0045A4CA47E23A4679ADCCC6FEB6B6A8A2E79E3032AC9DCF4E", 9, 5} =>
      {3_491_065_372, 1_210_440_480, 3_178_051_631},
    {:producer, "AFBBFA2030270377A2ECE63644380BEB3848C17B04B1DDFA7E4ACA98D62D", 0, 3} =>
      {1_371_539_577, 104_943_859, 3_778_747_399},
    {:producer, "2E80B966016539ACAF3158608745EAF3869C02012C0B5FAB2874099D4B79", 5, 0} =>
      {4_137_627_184, 948_196_154, 1_017_983_108},
    {:producer, "935E08BA5C0045A4CA47E23A4679ADCCC6FEB6B6A8A2E79E3032AC9DCF4E", 5, 3} =>
      {1_320_042_764, 417_200_582, 3_314_512_258},
    {:producer, "BFBD0260BA02B81EFC02BF20D2ECDAEAA44490BD10F5744A0F5A3CB85CD2", 1, 0} =>
      {4_293_039_752, 1_131_028_709, 2_209_052_536},
    {:consumer, "5333C7C3855A872BEF8F5812209D849A8336B78AB54D5A28AD298EF95107", 4,
     "SimulatorGroup1", 2} => {4_011_529_217, 1_835_066_907, 917_189_914},
    {:producer, "BFBD0260BA02B81EFC02BF20D2ECDAEAA44490BD10F5744A0F5A3CB85CD2", 4, 7} =>
      {1_666_011_333, 2_594_752_903, 3_178_844_429},
    {:producer, "17A06A9E2B70472E0908AD7AA39C332653B51EB9D1FB9CAF59FCFAFF9AFE", 1, 2} =>
      {183_841_694, 2_475_072_111, 3_051_358_215},
    {:consumer, "7EEAA041FCBFFCFB1DFE676EFA6CD64BC03784DF0C3326F1AB8451B97767", 10,
     "SimulatorGroup1", 1} => {1_635_175_187, 3_870_514_214, 1_819_229_716},
    {:producer, "935E08BA5C0045A4CA47E23A4679ADCCC6FEB6B6A8A2E79E3032AC9DCF4E", 2, 0} =>
      {423_993_386, 1_378_203_216, 4_218_582_652},
    {:producer, "A442D3AE8CE988D98E73856B9E7B947F906683D5D35BBF022257B2747C30", 5, 3} =>
      {1_711_617_711, 3_962_222_390, 1_799_931_947},
    {:producer, "2E80B966016539ACAF3158608745EAF3869C02012C0B5FAB2874099D4B79", 8, 5} =>
      {2_262_446_749, 1_043_569_401, 551_999_276},
    {:producer, "5333C7C3855A872BEF8F5812209D849A8336B78AB54D5A28AD298EF95107", 1, 0} =>
      {2_923_409_033, 931_541_644, 3_158_233_606},
    {:producer, "935E08BA5C0045A4CA47E23A4679ADCCC6FEB6B6A8A2E79E3032AC9DCF4E", 6, 7} =>
      {3_661_191_102, 2_933_827_459, 2_436_934_994},
    {:producer, "5333C7C3855A872BEF8F5812209D849A8336B78AB54D5A28AD298EF95107", 0, 5} =>
      {435_452_521, 39_556_004, 1_823_237_634},
    {:producer, "935E08BA5C0045A4CA47E23A4679ADCCC6FEB6B6A8A2E79E3032AC9DCF4E", 0, 0} =>
      {2_941_465_579, 411_061_065, 3_926_458_519},
    {:consumer, "A442D3AE8CE988D98E73856B9E7B947F906683D5D35BBF022257B2747C30", 0,
     "SimulatorGroup1", 2} => {758_375_722, 1_719_537_513, 1_280_180_276},
    {:producer, "5333C7C3855A872BEF8F5812209D849A8336B78AB54D5A28AD298EF95107", 4, 4} =>
      {1_031_782_019, 281_636_293, 555_269_260},
    {:producer, "5333C7C3855A872BEF8F5812209D849A8336B78AB54D5A28AD298EF95107", 7, 5} =>
      {3_255_076_290, 1_652_787_216, 2_083_876_662},
    {:producer, "935E08BA5C0045A4CA47E23A4679ADCCC6FEB6B6A8A2E79E3032AC9DCF4E", 9, 3} =>
      {2_153_707_409, 4_259_699_489, 3_473_107_504},
    {:consumer, "2E80B966016539ACAF3158608745EAF3869C02012C0B5FAB2874099D4B79", 3,
     "SimulatorGroup1", 0} => {2_887_060_943, 3_763_787_173, 768_511_778},
    {:producer, "935E08BA5C0045A4CA47E23A4679ADCCC6FEB6B6A8A2E79E3032AC9DCF4E", 0, 3} =>
      {239_524_592, 2_333_305_747, 3_909_239_324},
    {:producer, "7EEAA041FCBFFCFB1DFE676EFA6CD64BC03784DF0C3326F1AB8451B97767", 10, 0} =>
      {2_505_519_593, 1_034_835_341, 1_667_247_298},
    {:consumer, "7EEAA041FCBFFCFB1DFE676EFA6CD64BC03784DF0C3326F1AB8451B97767", 9,
     "SimulatorGroup1", 0} => {714_374_518, 2_642_476_419, 4_008_938_247},
    {:producer, "17A06A9E2B70472E0908AD7AA39C332653B51EB9D1FB9CAF59FCFAFF9AFE", 3, 7} =>
      {2_537_677_359, 2_569_237_696, 1_010_343_158},
    {:producer, "935E08BA5C0045A4CA47E23A4679ADCCC6FEB6B6A8A2E79E3032AC9DCF4E", 6, 5} =>
      {3_025_507_237, 4_204_836_843, 1_506_392_265},
    {:producer, "A442D3AE8CE988D98E73856B9E7B947F906683D5D35BBF022257B2747C30", 4, 7} =>
      {886_718_418, 3_592_682_293, 2_279_905_868},
    {:producer, "2E80B966016539ACAF3158608745EAF3869C02012C0B5FAB2874099D4B79", 5, 5} =>
      {1_067_780_261, 1_792_973_413, 2_138_449_133},
    {:consumer, "935E08BA5C0045A4CA47E23A4679ADCCC6FEB6B6A8A2E79E3032AC9DCF4E", 3,
     "SimulatorGroup1", 2} => {4_212_410_951, 4_115_600_191, 4_029_452_399},
    {:producer, "935E08BA5C0045A4CA47E23A4679ADCCC6FEB6B6A8A2E79E3032AC9DCF4E", 4, 2} =>
      {2_608_509_179, 2_686_246_871, 2_988_503_839},
    {:producer, "7EEAA041FCBFFCFB1DFE676EFA6CD64BC03784DF0C3326F1AB8451B97767", 8, 6} =>
      {3_973_159_412, 3_659_620_969, 1_169_216_722},
    {:producer, "A442D3AE8CE988D98E73856B9E7B947F906683D5D35BBF022257B2747C30", 3, 0} =>
      {1_073_268_315, 4_258_759_894, 4_059_108_356},
    {:producer, "A442D3AE8CE988D98E73856B9E7B947F906683D5D35BBF022257B2747C30", 5, 7} =>
      {2_701_399_294, 3_248_947_475, 2_284_325_020},
    {:producer, "5333C7C3855A872BEF8F5812209D849A8336B78AB54D5A28AD298EF95107", 6, 6} =>
      {2_303_529_204, 2_568_952_643, 3_349_540_645},
    {:consumer, "5333C7C3855A872BEF8F5812209D849A8336B78AB54D5A28AD298EF95107", 6,
     "SimulatorGroup1", 1} => {4_187_741_682, 1_672_310_552, 2_242_626_539},
    {:producer, "935E08BA5C0045A4CA47E23A4679ADCCC6FEB6B6A8A2E79E3032AC9DCF4E", 8, 1} =>
      {2_546_496_717, 1_276_381_040, 1_364_720_552},
    {:producer, "935E08BA5C0045A4CA47E23A4679ADCCC6FEB6B6A8A2E79E3032AC9DCF4E", 7, 6} =>
      {373_875_617, 2_654_388_962, 1_689_644_946},
    {:producer, "AFBBFA2030270377A2ECE63644380BEB3848C17B04B1DDFA7E4ACA98D62D", 0, 0} =>
      {850_270_763, 2_553_928_152, 2_113_291_557},
    {:producer, "A442D3AE8CE988D98E73856B9E7B947F906683D5D35BBF022257B2747C30", 5, 2} =>
      {2_496_198_610, 1_503_079_595, 555_492_313},
    {:producer, "935E08BA5C0045A4CA47E23A4679ADCCC6FEB6B6A8A2E79E3032AC9DCF4E", 8, 4} =>
      {3_510_103_803, 2_522_355_379, 3_654_500_066},
    {:producer, "17A06A9E2B70472E0908AD7AA39C332653B51EB9D1FB9CAF59FCFAFF9AFE", 0, 7} =>
      {3_422_628_283, 192_088_427, 3_708_967_973},
    {:producer, "5333C7C3855A872BEF8F5812209D849A8336B78AB54D5A28AD298EF95107", 4, 7} =>
      {887_538_290, 2_543_526_704, 3_924_071_611},
    {:producer, "A442D3AE8CE988D98E73856B9E7B947F906683D5D35BBF022257B2747C30", 4, 0} =>
      {193_372_301, 2_731_382_390, 3_422_937_614},
    {:producer, "7EEAA041FCBFFCFB1DFE676EFA6CD64BC03784DF0C3326F1AB8451B97767", 6, 6} =>
      {2_700_444_832, 1_175_438_935, 3_171_873_727},
    {:producer, "2E80B966016539ACAF3158608745EAF3869C02012C0B5FAB2874099D4B79", 6, 3} =>
      {1_778_678_456, 1_635_314_199, 4_188_812_456},
    {:producer, "935E08BA5C0045A4CA47E23A4679ADCCC6FEB6B6A8A2E79E3032AC9DCF4E", 4, 0} =>
      {1_588_558_185, 1_375_025_238, 1_003_916_659},
    {:producer, "7EEAA041FCBFFCFB1DFE676EFA6CD64BC03784DF0C3326F1AB8451B97767", 9, 7} =>
      {3_398_352_648, 3_552_723_020, 2_918_148_668},
    {:consumer, "A442D3AE8CE988D98E73856B9E7B947F906683D5D35BBF022257B2747C30", 1,
     "SimulatorGroup1", 1} => {87_873_739, 4_007_673_021, 149_435_173},
    {:producer, "2E80B966016539ACAF3158608745EAF3869C02012C0B5FAB2874099D4B79", 4, 6} =>
      {841_295_244, 1_009_434_811, 3_833_521_554},
    {:producer, "A442D3AE8CE988D98E73856B9E7B947F906683D5D35BBF022257B2747C30", 5, 5} =>
      {1_884_144_249, 4_282_144_719, 3_437_827_428},
    {:consumer, "7EEAA041FCBFFCFB1DFE676EFA6CD64BC03784DF0C3326F1AB8451B97767", 7,
     "SimulatorGroup1", 2} => {1_054_234_544, 3_534_319_671, 1_514_874_187},
    {:consumer, "5333C7C3855A872BEF8F5812209D849A8336B78AB54D5A28AD298EF95107", 1,
     "SimulatorGroup1", 0} => {2_912_192_139, 3_826_863_005, 876_894_959},
    {:consumer, "A442D3AE8CE988D98E73856B9E7B947F906683D5D35BBF022257B2747C30", 2,
     "SimulatorGroup1", 1} => {10_480_895, 1_257_498_593, 268_346_291},
    {:producer, "935E08BA5C0045A4CA47E23A4679ADCCC6FEB6B6A8A2E79E3032AC9DCF4E", 5, 7} =>
      {64_326_818, 2_232_030_617, 896_444_812},
    {:consumer, "7EEAA041FCBFFCFB1DFE676EFA6CD64BC03784DF0C3326F1AB8451B97767", 7,
     "SimulatorGroup1", 0} => {3_785_617_268, 1_794_372_542, 3_180_812_917},
    {:producer, "AFBBFA2030270377A2ECE63644380BEB3848C17B04B1DDFA7E4ACA98D62D", 1, 6} =>
      {2_416_495_926, 2_348_342_430, 1_629_940_530},
    {:producer, "5333C7C3855A872BEF8F5812209D849A8336B78AB54D5A28AD298EF95107", 1, 3} =>
      {628_350_331, 4_033_903_482, 494_165_247},
    {:producer, "BFBD0260BA02B81EFC02BF20D2ECDAEAA44490BD10F5744A0F5A3CB85CD2", 2, 3} =>
      {1_246_541_091, 3_241_969_517, 3_273_614_588},
    {:producer, "A442D3AE8CE988D98E73856B9E7B947F906683D5D35BBF022257B2747C30", 4, 3} =>
      {1_845_057_586, 1_004_883_965, 1_960_175_761},
    {:consumer, "935E08BA5C0045A4CA47E23A4679ADCCC6FEB6B6A8A2E79E3032AC9DCF4E", 4,
     "SimulatorGroup1", 2} => {1_009_275_922, 2_603_068_590, 2_344_854_880},
    {:producer, "7EEAA041FCBFFCFB1DFE676EFA6CD64BC03784DF0C3326F1AB8451B97767", 1, 2} =>
      {726_155_321, 3_673_805_571, 839_523_337},
    {:producer, "A442D3AE8CE988D98E73856B9E7B947F906683D5D35BBF022257B2747C30", 1, 6} =>
      {1_796_525_902, 683_192_066, 166_196_669},
    {:producer, "7EEAA041FCBFFCFB1DFE676EFA6CD64BC03784DF0C3326F1AB8451B97767", 6, 3} =>
      {1_567_723_557, 2_555_609_089, 3_154_797_589},
    {:producer, "7EEAA041FCBFFCFB1DFE676EFA6CD64BC03784DF0C3326F1AB8451B97767", 8, 7} =>
      {3_318_910_850, 2_473_323_198, 3_414_708_728},
    {:producer, "935E08BA5C0045A4CA47E23A4679ADCCC6FEB6B6A8A2E79E3032AC9DCF4E", 4, 6} =>
      {3_630_709_648, 779_326_105, 2_763_447_628},
    {:producer, "2E80B966016539ACAF3158608745EAF3869C02012C0B5FAB2874099D4B79", 2, 4} =>
      {1_254_065_963, 3_470_031_985, 3_121_855_789},
    {:consumer, "935E08BA5C0045A4CA47E23A4679ADCCC6FEB6B6A8A2E79E3032AC9DCF4E", 5,
     "SimulatorGroup1", 0} => {3_988_956_921, 2_516_377_245, 122_955_720},
    {:producer, "AFBBFA2030270377A2ECE63644380BEB3848C17B04B1DDFA7E4ACA98D62D", 1, 7} =>
      {3_248_251_087, 1_627_363_124, 375_707_282},
    {:producer, "BFBD0260BA02B81EFC02BF20D2ECDAEAA44490BD10F5744A0F5A3CB85CD2", 3, 4} =>
      {1_492_271_224, 434_840_254, 4_237_306_836},
    {:producer, "935E08BA5C0045A4CA47E23A4679ADCCC6FEB6B6A8A2E79E3032AC9DCF4E", 5, 0} =>
      {2_304_640_766, 3_009_473_871, 1_082_293_487},
    {:consumer, "935E08BA5C0045A4CA47E23A4679ADCCC6FEB6B6A8A2E79E3032AC9DCF4E", 0,
     "SimulatorGroup1", 2} => {208_941_986, 2_848_658_230, 314_393_391},
    {:producer, "5333C7C3855A872BEF8F5812209D849A8336B78AB54D5A28AD298EF95107", 3, 2} =>
      {2_824_446_337, 2_204_576_169, 1_740_193_671},
    {:producer, "7EEAA041FCBFFCFB1DFE676EFA6CD64BC03784DF0C3326F1AB8451B97767", 2, 3} =>
      {3_550_645_444, 4_195_599_114, 457_156_939},
    {:consumer, "7EEAA041FCBFFCFB1DFE676EFA6CD64BC03784DF0C3326F1AB8451B97767", 6,
     "SimulatorGroup1", 0} => {3_686_735_246, 336_025_956, 440_802_793},
    {:producer, "2E80B966016539ACAF3158608745EAF3869C02012C0B5FAB2874099D4B79", 5, 6} =>
      {959_435_292, 1_132_977_781, 654_145_738},
    {:producer, "7EEAA041FCBFFCFB1DFE676EFA6CD64BC03784DF0C3326F1AB8451B97767", 1, 5} =>
      {2_351_579_967, 305_982_084, 2_177_815_208},
    {:producer, "2E80B966016539ACAF3158608745EAF3869C02012C0B5FAB2874099D4B79", 8, 6} =>
      {1_833_746_100, 1_248_513_526, 2_998_407_617},
    {:producer, "A442D3AE8CE988D98E73856B9E7B947F906683D5D35BBF022257B2747C30", 6, 2} =>
      {1_413_902_362, 2_567_253_809, 3_167_229_178},
    {:producer, "5333C7C3855A872BEF8F5812209D849A8336B78AB54D5A28AD298EF95107", 3, 7} =>
      {1_344_732_519, 1_266_693_734, 3_080_417_533},
    {:consumer, "2E80B966016539ACAF3158608745EAF3869C02012C0B5FAB2874099D4B79", 7,
     "SimulatorGroup1", 0} => {2_293_698_987, 4_194_134_546, 1_622_371_219},
    {:producer, "BFBD0260BA02B81EFC02BF20D2ECDAEAA44490BD10F5744A0F5A3CB85CD2", 1, 3} =>
      {875_814_664, 2_325_960_845, 1_131_987_326},
    {:producer, "2E80B966016539ACAF3158608745EAF3869C02012C0B5FAB2874099D4B79", 9, 3} =>
      {44_904_039, 2_759_926_970, 1_111_762_129},
    {:producer, "A442D3AE8CE988D98E73856B9E7B947F906683D5D35BBF022257B2747C30", 3, 3} =>
      {2_063_783_188, 1_708_955_773, 659_948_888},
    {:producer, "935E08BA5C0045A4CA47E23A4679ADCCC6FEB6B6A8A2E79E3032AC9DCF4E", 3, 7} =>
      {3_283_020_756, 2_318_542_585, 2_681_247_546},
    {:producer, "2E80B966016539ACAF3158608745EAF3869C02012C0B5FAB2874099D4B79", 8, 4} =>
      {1_128_353_533, 178_096_329, 2_526_745_412},
    {:consumer, "935E08BA5C0045A4CA47E23A4679ADCCC6FEB6B6A8A2E79E3032AC9DCF4E", 6,
     "SimulatorGroup1", 1} => {1_544_290_125, 3_303_131_243, 4_062_069_784},
    {:consumer, "2E80B966016539ACAF3158608745EAF3869C02012C0B5FAB2874099D4B79", 9,
     "SimulatorGroup1", 2} => {1_974_402_887, 3_001_541_530, 2_122_391_662},
    {:producer, "7EEAA041FCBFFCFB1DFE676EFA6CD64BC03784DF0C3326F1AB8451B97767", 6, 1} =>
      {2_911_324_577, 132_034_489, 1_720_608_616},
    {:producer, "BFBD0260BA02B81EFC02BF20D2ECDAEAA44490BD10F5744A0F5A3CB85CD2", 4, 4} =>
      {3_455_272_727, 1_151_967_140, 4_270_013_383},
    {:consumer, "BFBD0260BA02B81EFC02BF20D2ECDAEAA44490BD10F5744A0F5A3CB85CD2", 3,
     "SimulatorGroup1", 0} => {4_056_303_634, 3_454_555_404, 3_255_576_145},
    {:producer, "2E80B966016539ACAF3158608745EAF3869C02012C0B5FAB2874099D4B79", 4, 5} =>
      {1_150_194_755, 2_980_107_323, 2_543_036_636},
    {:producer, "2E80B966016539ACAF3158608745EAF3869C02012C0B5FAB2874099D4B79", 3, 3} =>
      {2_585_451_898, 3_861_391_731, 4_115_610_563},
    {:producer, "5333C7C3855A872BEF8F5812209D849A8336B78AB54D5A28AD298EF95107", 7, 0} =>
      {3_825_692_771, 1_621_389_197, 2_059_949_040},
    {:producer, "935E08BA5C0045A4CA47E23A4679ADCCC6FEB6B6A8A2E79E3032AC9DCF4E", 3, 0} =>
      {1_311_171_175, 1_019_797_672, 3_370_259_499},
    {:producer, "2E80B966016539ACAF3158608745EAF3869C02012C0B5FAB2874099D4B79", 6, 5} =>
      {2_171_986_745, 899_690_370, 2_824_763_243},
    {:consumer, "17A06A9E2B70472E0908AD7AA39C332653B51EB9D1FB9CAF59FCFAFF9AFE", 1,
     "SimulatorGroup1", 1} => {3_612_082_024, 1_570_580_380, 4_150_773_175},
    {:producer, "5333C7C3855A872BEF8F5812209D849A8336B78AB54D5A28AD298EF95107", 4, 3} =>
      {4_020_391_802, 3_020_580_424, 1_567_708_411},
    {:producer, "7EEAA041FCBFFCFB1DFE676EFA6CD64BC03784DF0C3326F1AB8451B97767", 11, 5} =>
      {645_989_067, 4_055_069_671, 1_095_373_066},
    {:producer, "7EEAA041FCBFFCFB1DFE676EFA6CD64BC03784DF0C3326F1AB8451B97767", 10, 3} =>
      {3_095_192_507, 279_131_700, 2_661_602_146},
    {:producer, "7EEAA041FCBFFCFB1DFE676EFA6CD64BC03784DF0C3326F1AB8451B97767", 10, 1} =>
      {4_274_784_708, 333_533_441, 2_808_846_329},
    {:producer, "5333C7C3855A872BEF8F5812209D849A8336B78AB54D5A28AD298EF95107", 5, 6} =>
      {2_391_097_910, 2_411_321_613, 3_765_850_560},
    {:consumer, "7EEAA041FCBFFCFB1DFE676EFA6CD64BC03784DF0C3326F1AB8451B97767", 1,
     "SimulatorGroup1", 2} => {2_430_948_476, 1_935_169_770, 2_109_915_576},
    {:producer, "935E08BA5C0045A4CA47E23A4679ADCCC6FEB6B6A8A2E79E3032AC9DCF4E", 7, 5} =>
      {2_191_839_006, 4_068_236_196, 3_894_677_769},
    {:producer, "7EEAA041FCBFFCFB1DFE676EFA6CD64BC03784DF0C3326F1AB8451B97767", 3, 6} =>
      {2_989_695_311, 3_970_846_565, 1_720_779_070},
    {:consumer, "5333C7C3855A872BEF8F5812209D849A8336B78AB54D5A28AD298EF95107", 5,
     "SimulatorGroup1", 0} => {2_889_453_215, 3_270_885_752, 2_149_984_965},
    {:producer, "A442D3AE8CE988D98E73856B9E7B947F906683D5D35BBF022257B2747C30", 6, 5} =>
      {614_626_689, 3_721_981_111, 3_329_865_887},
    {:producer, "935E08BA5C0045A4CA47E23A4679ADCCC6FEB6B6A8A2E79E3032AC9DCF4E", 3, 6} =>
      {1_460_222_871, 3_258_579_118, 145_003_007},
    {:consumer, "5333C7C3855A872BEF8F5812209D849A8336B78AB54D5A28AD298EF95107", 3,
     "SimulatorGroup1", 0} => {950_017_198, 1_575_415_334, 1_000_535_173},
    {:producer, "AFBBFA2030270377A2ECE63644380BEB3848C17B04B1DDFA7E4ACA98D62D", 2, 0} =>
      {302_673_355, 3_253_344_996, 869_854_396},
    {:producer, "2E80B966016539ACAF3158608745EAF3869C02012C0B5FAB2874099D4B79", 1, 3} =>
      {11_721_970, 4_105_540_206, 3_531_383_321},
    {:producer, "17A06A9E2B70472E0908AD7AA39C332653B51EB9D1FB9CAF59FCFAFF9AFE", 0, 5} =>
      {2_943_376_539, 3_704_757_525, 1_719_865_774},
    {:producer, "5333C7C3855A872BEF8F5812209D849A8336B78AB54D5A28AD298EF95107", 5, 0} =>
      {3_382_598_041, 3_629_609_017, 3_880_653_538},
    {:producer, "5333C7C3855A872BEF8F5812209D849A8336B78AB54D5A28AD298EF95107", 2, 6} =>
      {2_961_539_422, 665_401_453, 4_156_410_117},
    {:consumer, "17A06A9E2B70472E0908AD7AA39C332653B51EB9D1FB9CAF59FCFAFF9AFE", 0,
     "SimulatorGroup1", 1} => {523_744_413, 2_298_107_625, 3_272_998_136},
    {:producer, "935E08BA5C0045A4CA47E23A4679ADCCC6FEB6B6A8A2E79E3032AC9DCF4E", 1, 0} =>
      {4_001_166_658, 2_889_724_781, 1_058_264_196},
    {:producer, "A442D3AE8CE988D98E73856B9E7B947F906683D5D35BBF022257B2747C30", 6, 4} =>
      {1_379_163_971, 2_881_773, 1_454_135_109},
    {:consumer, "17A06A9E2B70472E0908AD7AA39C332653B51EB9D1FB9CAF59FCFAFF9AFE", 1,
     "SimulatorGroup1", 2} => {4_228_156_221, 1_000_713_325, 852_893_804},
    {:producer, "7EEAA041FCBFFCFB1DFE676EFA6CD64BC03784DF0C3326F1AB8451B97767", 10, 5} =>
      {1_381_764_989, 1_349_831_234, 3_358_247_479},
    {:consumer, "AFBBFA2030270377A2ECE63644380BEB3848C17B04B1DDFA7E4ACA98D62D", 1,
     "SimulatorGroup1", 0} => {1_885_668_295, 2_815_688_566, 395_125_605},
    {:consumer, "AFBBFA2030270377A2ECE63644380BEB3848C17B04B1DDFA7E4ACA98D62D", 1,
     "SimulatorGroup1", 1} => {865_313_799, 427_124_681, 2_380_640_215},
    {:producer, "AFBBFA2030270377A2ECE63644380BEB3848C17B04B1DDFA7E4ACA98D62D", 2, 1} =>
      {1_966_146_587, 2_845_374_404, 3_286_011_206},
    {:producer, "935E08BA5C0045A4CA47E23A4679ADCCC6FEB6B6A8A2E79E3032AC9DCF4E", 2, 3} =>
      {3_836_090_073, 2_346_689_862, 919_231_386},
    {:consumer, "A442D3AE8CE988D98E73856B9E7B947F906683D5D35BBF022257B2747C30", 0,
     "SimulatorGroup1", 0} => {2_358_876_032, 2_715_166_289, 311_316_136},
    {:producer, "A442D3AE8CE988D98E73856B9E7B947F906683D5D35BBF022257B2747C30", 5, 6} =>
      {422_733_988, 329_953_020, 2_687_588_104},
    {:producer, "A442D3AE8CE988D98E73856B9E7B947F906683D5D35BBF022257B2747C30", 1, 4} =>
      {291_940_717, 998_773_720, 4_025_437_288},
    {:producer, "935E08BA5C0045A4CA47E23A4679ADCCC6FEB6B6A8A2E79E3032AC9DCF4E", 1, 5} =>
      {2_577_140_778, 3_342_675_377, 856_155_014},
    {:producer, "5333C7C3855A872BEF8F5812209D849A8336B78AB54D5A28AD298EF95107", 0, 2} =>
      {1_358_155_778, 2_213_950_567, 334_676_680},
    {:producer, "5333C7C3855A872BEF8F5812209D849A8336B78AB54D5A28AD298EF95107", 1, 1} =>
      {622_327_924, 3_338_935_220, 2_029_237_928},
    {:producer, "17A06A9E2B70472E0908AD7AA39C332653B51EB9D1FB9CAF59FCFAFF9AFE", 1, 0} =>
      {9_600_820, 812_929_340, 3_724_689_448},
    {:producer, "2E80B966016539ACAF3158608745EAF3869C02012C0B5FAB2874099D4B79", 5, 4} =>
      {320_603_143, 427_112_229, 1_009_732_311},
    {:producer, "A442D3AE8CE988D98E73856B9E7B947F906683D5D35BBF022257B2747C30", 2, 0} =>
      {2_486_677_390, 2_479_594_119, 4_230_393_123},
    {:producer, "A442D3AE8CE988D98E73856B9E7B947F906683D5D35BBF022257B2747C30", 4, 2} =>
      {965_753_615, 97_606_639, 3_570_592_609},
    {:producer, "2E80B966016539ACAF3158608745EAF3869C02012C0B5FAB2874099D4B79", 1, 1} =>
      {3_484_143_409, 712_793_082, 3_680_691_179},
    {:producer, "2E80B966016539ACAF3158608745EAF3869C02012C0B5FAB2874099D4B79", 4, 4} =>
      {2_989_665_180, 2_719_801_566, 2_551_680_958},
    {:producer, "2E80B966016539ACAF3158608745EAF3869C02012C0B5FAB2874099D4B79", 6, 4} =>
      {2_530_628_368, 965_150_227, 2_395_018_621},
    {:producer, "17A06A9E2B70472E0908AD7AA39C332653B51EB9D1FB9CAF59FCFAFF9AFE", 0, 3} =>
      {3_289_825_089, 2_454_081_344, 1_278_472_356},
    {:producer, "7EEAA041FCBFFCFB1DFE676EFA6CD64BC03784DF0C3326F1AB8451B97767", 5, 4} =>
      {2_376_197_723, 163_618_907, 3_250_477_334},
    {:producer, "BFBD0260BA02B81EFC02BF20D2ECDAEAA44490BD10F5744A0F5A3CB85CD2", 3, 7} =>
      {2_733_378_190, 3_161_784_214, 3_956_544_394},
    {:consumer, "7EEAA041FCBFFCFB1DFE676EFA6CD64BC03784DF0C3326F1AB8451B97767", 0,
     "SimulatorGroup1", 1} => {178_343_938, 2_571_554_445, 528_580_877},
    {:producer, "935E08BA5C0045A4CA47E23A4679ADCCC6FEB6B6A8A2E79E3032AC9DCF4E", 1, 1} =>
      {4_205_905_229, 3_156_291_146, 3_628_296_948},
    {:producer, "935E08BA5C0045A4CA47E23A4679ADCCC6FEB6B6A8A2E79E3032AC9DCF4E", 10, 7} =>
      {2_401_308_010, 602_823_657, 3_439_914_423},
    {:consumer, "935E08BA5C0045A4CA47E23A4679ADCCC6FEB6B6A8A2E79E3032AC9DCF4E", 8,
     "SimulatorGroup1", 2} => {1_506_143_729, 1_517_444_527, 1_985_653_185},
    {:producer, "A442D3AE8CE988D98E73856B9E7B947F906683D5D35BBF022257B2747C30", 1, 5} =>
      {4_088_247_896, 3_698_985_653, 1_974_550_211},
    {:producer, "7EEAA041FCBFFCFB1DFE676EFA6CD64BC03784DF0C3326F1AB8451B97767", 9, 4} =>
      {1_667_805_029, 3_203_101_874, 1_397_302_288},
    {:producer, "7EEAA041FCBFFCFB1DFE676EFA6CD64BC03784DF0C3326F1AB8451B97767", 4, 6} =>
      {3_380_224_484, 2_722_597_959, 2_627_779_156},
    {:consumer, "AFBBFA2030270377A2ECE63644380BEB3848C17B04B1DDFA7E4ACA98D62D", 1,
     "SimulatorGroup1", 2} => {4_151_069_866, 1_264_375_625, 3_686_206_261},
    {:consumer, "2E80B966016539ACAF3158608745EAF3869C02012C0B5FAB2874099D4B79", 8,
     "SimulatorGroup1", 1} => {776_269_346, 4_274_618_496, 3_690_809_511},
    {:consumer, "2E80B966016539ACAF3158608745EAF3869C02012C0B5FAB2874099D4B79", 7,
     "SimulatorGroup1", 2} => {3_000_798_196, 2_866_771_851, 3_125_908_243},
    {:producer, "7EEAA041FCBFFCFB1DFE676EFA6CD64BC03784DF0C3326F1AB8451B97767", 0, 6} =>
      {3_356_509_202, 173_281_945, 2_298_615_428},
    {:consumer, "7EEAA041FCBFFCFB1DFE676EFA6CD64BC03784DF0C3326F1AB8451B97767", 11,
     "SimulatorGroup1", 2} => {2_651_484_094, 253_630_310, 4_187_995_822},
    {:producer, "7EEAA041FCBFFCFB1DFE676EFA6CD64BC03784DF0C3326F1AB8451B97767", 7, 3} =>
      {1_886_057_534, 290_885_197, 1_753_851_256},
    {:producer, "2E80B966016539ACAF3158608745EAF3869C02012C0B5FAB2874099D4B79", 9, 5} =>
      {3_401_747_808, 2_072_032_858, 3_513_719_445},
    {:consumer, "2E80B966016539ACAF3158608745EAF3869C02012C0B5FAB2874099D4B79", 4,
     "SimulatorGroup1", 0} => {380_678_139, 3_419_289_539, 4_078_860_103},
    {:producer, "5333C7C3855A872BEF8F5812209D849A8336B78AB54D5A28AD298EF95107", 7, 4} =>
      {3_468_867_053, 2_291_201_992, 734_432_132},
    {:consumer, "2E80B966016539ACAF3158608745EAF3869C02012C0B5FAB2874099D4B79", 6,
     "SimulatorGroup1", 0} => {709_096_448, 934_067_584, 4_038_015_328},
    {:producer, "2E80B966016539ACAF3158608745EAF3869C02012C0B5FAB2874099D4B79", 1, 2} =>
      {383_801_798, 1_960_547_765, 853_487_295},
    {:producer, "5333C7C3855A872BEF8F5812209D849A8336B78AB54D5A28AD298EF95107", 3, 1} =>
      {482_550_777, 3_066_178_061, 762_004_688},
    {:producer, "7EEAA041FCBFFCFB1DFE676EFA6CD64BC03784DF0C3326F1AB8451B97767", 11, 6} =>
      {3_302_849_120, 2_523_904_760, 815_847_361},
    {:consumer, "935E08BA5C0045A4CA47E23A4679ADCCC6FEB6B6A8A2E79E3032AC9DCF4E", 10,
     "SimulatorGroup1", 1} => {300_572_572, 841_992_026, 1_705_575_747},
    {:producer, "7EEAA041FCBFFCFB1DFE676EFA6CD64BC03784DF0C3326F1AB8451B97767", 8, 1} =>
      {4_161_787_731, 4_182_117_397, 2_996_716_161},
    {:producer, "A442D3AE8CE988D98E73856B9E7B947F906683D5D35BBF022257B2747C30", 5, 0} =>
      {791_825_022, 752_887_285, 1_034_235_792},
    {:producer, "BFBD0260BA02B81EFC02BF20D2ECDAEAA44490BD10F5744A0F5A3CB85CD2", 0, 1} =>
      {3_272_737_388, 295_060_806, 1_053_317_550},
    {:consumer, "5333C7C3855A872BEF8F5812209D849A8336B78AB54D5A28AD298EF95107", 7,
     "SimulatorGroup1", 2} => {1_288_276_502, 3_146_199_319, 941_938_981},
    {:producer, "A442D3AE8CE988D98E73856B9E7B947F906683D5D35BBF022257B2747C30", 3, 6} =>
      {584_806_859, 3_868_096_282, 878_428_434},
    {:producer, "935E08BA5C0045A4CA47E23A4679ADCCC6FEB6B6A8A2E79E3032AC9DCF4E", 7, 1} =>
      {2_496_528_473, 594_705_976, 331_013_385},
    {:consumer, "17A06A9E2B70472E0908AD7AA39C332653B51EB9D1FB9CAF59FCFAFF9AFE", 2,
     "SimulatorGroup1", 0} => {3_797_773_380, 1_917_696_053, 2_145_183_505},
    {:consumer, "935E08BA5C0045A4CA47E23A4679ADCCC6FEB6B6A8A2E79E3032AC9DCF4E", 8,
     "SimulatorGroup1", 1} => {3_003_624_340, 1_661_484_923, 2_855_891_716},
    {:producer, "2E80B966016539ACAF3158608745EAF3869C02012C0B5FAB2874099D4B79", 7, 3} =>
      {4_059_171_784, 2_801_910_465, 1_789_946_356},
    {:producer, "935E08BA5C0045A4CA47E23A4679ADCCC6FEB6B6A8A2E79E3032AC9DCF4E", 9, 7} =>
      {3_393_021_298, 4_253_587_117, 3_888_311_464},
    {:producer, "935E08BA5C0045A4CA47E23A4679ADCCC6FEB6B6A8A2E79E3032AC9DCF4E", 7, 3} =>
      {2_320_383_299, 2_350_799_590, 3_688_088_872},
    {:consumer, "7EEAA041FCBFFCFB1DFE676EFA6CD64BC03784DF0C3326F1AB8451B97767", 5,
     "SimulatorGroup1", 2} => {2_112_142_620, 575_439_674, 3_727_022_457},
    {:producer, "2E80B966016539ACAF3158608745EAF3869C02012C0B5FAB2874099D4B79", 8, 3} =>
      {3_830_487_400, 3_445_306_037, 1_802_896_343},
    {:consumer, "7EEAA041FCBFFCFB1DFE676EFA6CD64BC03784DF0C3326F1AB8451B97767", 4,
     "SimulatorGroup1", 1} => {2_741_573_574, 550_403_021, 1_075_987_145},
    {:producer, "BFBD0260BA02B81EFC02BF20D2ECDAEAA44490BD10F5744A0F5A3CB85CD2", 3, 3} =>
      {4_245_984_518, 907_389_127, 3_133_531_238},
    {:consumer, "935E08BA5C0045A4CA47E23A4679ADCCC6FEB6B6A8A2E79E3032AC9DCF4E", 10,
     "SimulatorGroup1", 0} => {3_302_674_564, 1_891_054_404, 3_210_766_124},
    {:consumer, "A442D3AE8CE988D98E73856B9E7B947F906683D5D35BBF022257B2747C30", 6,
     "SimulatorGroup1", 2} => {489_233_019, 2_041_737_739, 1_048_395_649},
    {:consumer, "5333C7C3855A872BEF8F5812209D849A8336B78AB54D5A28AD298EF95107", 6,
     "SimulatorGroup1", 0} => {2_159_722_592, 1_730_033_998, 668_490_883},
    {:consumer, "2E80B966016539ACAF3158608745EAF3869C02012C0B5FAB2874099D4B79", 4,
     "SimulatorGroup1", 1} => {2_272_475_348, 228_191_723, 3_824_230_432},
    {:consumer, "7EEAA041FCBFFCFB1DFE676EFA6CD64BC03784DF0C3326F1AB8451B97767", 3,
     "SimulatorGroup1", 1} => {1_770_306_028, 2_825_594_162, 4_016_309_048},
    {:consumer, "5333C7C3855A872BEF8F5812209D849A8336B78AB54D5A28AD298EF95107", 4,
     "SimulatorGroup1", 0} => {598_186_097, 1_383_849_295, 3_685_970_271},
    {:producer, "7EEAA041FCBFFCFB1DFE676EFA6CD64BC03784DF0C3326F1AB8451B97767", 11, 2} =>
      {951_696_285, 4_033_890_980, 1_948_779_838},
    {:producer, "2E80B966016539ACAF3158608745EAF3869C02012C0B5FAB2874099D4B79", 2, 2} =>
      {2_942_336_868, 413_420_917, 4_243_612_197},
    {:producer, "A442D3AE8CE988D98E73856B9E7B947F906683D5D35BBF022257B2747C30", 2, 7} =>
      {1_735_725_220, 1_614_620_713, 676_768_598},
    {:producer, "AFBBFA2030270377A2ECE63644380BEB3848C17B04B1DDFA7E4ACA98D62D", 1, 2} =>
      {2_870_425_344, 3_935_674_864, 580_546_438},
    {:consumer, "2E80B966016539ACAF3158608745EAF3869C02012C0B5FAB2874099D4B79", 5,
     "SimulatorGroup1", 2} => {3_041_125_889, 2_669_089_189, 2_144_257_625},
    {:producer, "935E08BA5C0045A4CA47E23A4679ADCCC6FEB6B6A8A2E79E3032AC9DCF4E", 7, 7} =>
      {2_659_964_035, 2_450_383_213, 2_786_016_714},
    {:producer, "7EEAA041FCBFFCFB1DFE676EFA6CD64BC03784DF0C3326F1AB8451B97767", 9, 2} =>
      {2_120_569_184, 2_326_088_169, 2_835_918_429},
    {:producer, "BFBD0260BA02B81EFC02BF20D2ECDAEAA44490BD10F5744A0F5A3CB85CD2", 2, 5} =>
      {1_464_279_617, 2_675_433_218, 3_584_565_877},
    {:consumer, "7EEAA041FCBFFCFB1DFE676EFA6CD64BC03784DF0C3326F1AB8451B97767", 6,
     "SimulatorGroup1", 2} => {516_000_708, 4_066_152_722, 311_266_144},
    {:producer, "935E08BA5C0045A4CA47E23A4679ADCCC6FEB6B6A8A2E79E3032AC9DCF4E", 3, 2} =>
      {3_665_067_520, 1_727_004_409, 2_307_200_650},
    {:consumer, "5333C7C3855A872BEF8F5812209D849A8336B78AB54D5A28AD298EF95107", 4,
     "SimulatorGroup1", 1} => {244_688_000, 3_891_925_960, 4_246_074_555},
    {:producer, "7EEAA041FCBFFCFB1DFE676EFA6CD64BC03784DF0C3326F1AB8451B97767", 1, 6} =>
      {2_286_357_353, 3_165_882_630, 2_712_916_128},
    {:consumer, "2E80B966016539ACAF3158608745EAF3869C02012C0B5FAB2874099D4B79", 3,
     "SimulatorGroup1", 2} => {2_955_847_269, 3_137_424_618, 1_778_460_986},
    {:producer, "A442D3AE8CE988D98E73856B9E7B947F906683D5D35BBF022257B2747C30", 2, 2} =>
      {2_877_938_111, 2_442_295_291, 3_368_320_110},
    {:consumer, "5333C7C3855A872BEF8F5812209D849A8336B78AB54D5A28AD298EF95107", 1,
     "SimulatorGroup1", 2} => {2_118_580_588, 3_460_257_117, 2_884_887_087},
    {:producer, "2E80B966016539ACAF3158608745EAF3869C02012C0B5FAB2874099D4B79", 6, 2} =>
      {2_067_846_781, 2_795_044_584, 2_800_985_971},
    {:consumer, "2E80B966016539ACAF3158608745EAF3869C02012C0B5FAB2874099D4B79", 9,
     "SimulatorGroup1", 0} => {2_412_988_828, 1_923_468_822, 1_688_498_220},
    {:producer, "2E80B966016539ACAF3158608745EAF3869C02012C0B5FAB2874099D4B79", 4, 2} =>
      {3_224_935_206, 2_290_158_568, 2_833_285_842},
    {:consumer, "A442D3AE8CE988D98E73856B9E7B947F906683D5D35BBF022257B2747C30", 2,
     "SimulatorGroup1", 0} => {2_744_649_143, 4_116_756_250, 3_923_138_228},
    {:producer, "5333C7C3855A872BEF8F5812209D849A8336B78AB54D5A28AD298EF95107", 5, 5} =>
      {4_135_754_677, 2_053_932_927, 1_916_066_530},
    {:producer, "2E80B966016539ACAF3158608745EAF3869C02012C0B5FAB2874099D4B79", 8, 0} =>
      {1_708_298_781, 2_530_981_761, 1_921_437_383},
    {:producer, "5333C7C3855A872BEF8F5812209D849A8336B78AB54D5A28AD298EF95107", 4, 6} =>
      {2_282_658_992, 3_197_248_570, 3_569_203_354},
    {:producer, "BFBD0260BA02B81EFC02BF20D2ECDAEAA44490BD10F5744A0F5A3CB85CD2", 3, 0} =>
      {84_266_517, 1_824_150_663, 3_945_398_582},
    {:producer, "2E80B966016539ACAF3158608745EAF3869C02012C0B5FAB2874099D4B79", 3, 5} =>
      {527_290_942, 1_322_124_207, 4_216_315_901},
    {:consumer, "BFBD0260BA02B81EFC02BF20D2ECDAEAA44490BD10F5744A0F5A3CB85CD2", 1,
     "SimulatorGroup1", 2} => {4_198_814_211, 883_087_858, 464_490_635},
    {:producer, "A442D3AE8CE988D98E73856B9E7B947F906683D5D35BBF022257B2747C30", 6, 6} =>
      {3_749_282_049, 3_555_186_707, 1_237_756_636},
    {:producer, "935E08BA5C0045A4CA47E23A4679ADCCC6FEB6B6A8A2E79E3032AC9DCF4E", 8, 0} =>
      {623_412_474, 2_590_601_345, 863_066_297},
    {:producer, "BFBD0260BA02B81EFC02BF20D2ECDAEAA44490BD10F5744A0F5A3CB85CD2", 2, 4} =>
      {3_684_176_385, 4_164_954_914, 939_988_393},
    {:producer, "935E08BA5C0045A4CA47E23A4679ADCCC6FEB6B6A8A2E79E3032AC9DCF4E", 2, 1} =>
      {52_820_554, 1_646_681_671, 947_257_793},
    {:producer, "7EEAA041FCBFFCFB1DFE676EFA6CD64BC03784DF0C3326F1AB8451B97767", 0, 5} =>
      {610_010_387, 1_615_217_507, 2_188_844_713},
    {:producer, "5333C7C3855A872BEF8F5812209D849A8336B78AB54D5A28AD298EF95107", 1, 5} =>
      {1_380_539_931, 1_465_701_427, 176_527_932},
    {:producer, "935E08BA5C0045A4CA47E23A4679ADCCC6FEB6B6A8A2E79E3032AC9DCF4E", 7, 4} =>
      {1_577_579_109, 4_008_799_640, 497_133_925},
    {:producer, "935E08BA5C0045A4CA47E23A4679ADCCC6FEB6B6A8A2E79E3032AC9DCF4E", 6, 3} =>
      {334_117_815, 1_015_079_605, 113_155_465},
    {:consumer, "BFBD0260BA02B81EFC02BF20D2ECDAEAA44490BD10F5744A0F5A3CB85CD2", 4,
     "SimulatorGroup1", 2} => {548_965_715, 3_059_289_687, 2_456_978_943},
    {:producer, "7EEAA041FCBFFCFB1DFE676EFA6CD64BC03784DF0C3326F1AB8451B97767", 11, 4} =>
      {2_592_885_702, 1_046_800_374, 2_391_700_928},
    {:producer, "A442D3AE8CE988D98E73856B9E7B947F906683D5D35BBF022257B2747C30", 4, 5} =>
      {3_922_285_645, 728_287_527, 769_367_329},
    {:producer, "7EEAA041FCBFFCFB1DFE676EFA6CD64BC03784DF0C3326F1AB8451B97767", 3, 2} =>
      {3_863_894_331, 454_397_415, 568_451_427},
    {:producer, "5333C7C3855A872BEF8F5812209D849A8336B78AB54D5A28AD298EF95107", 5, 4} =>
      {3_056_212_576, 3_156_204_474, 2_478_338_177},
    {:producer, "5333C7C3855A872BEF8F5812209D849A8336B78AB54D5A28AD298EF95107", 5, 7} =>
      {1_577_494_312, 2_482_305_188, 1_039_450_070},
    {:producer, "935E08BA5C0045A4CA47E23A4679ADCCC6FEB6B6A8A2E79E3032AC9DCF4E", 7, 0} =>
      {1_986_292_001, 2_525_470_133, 3_341_078_822},
    {:producer, "17A06A9E2B70472E0908AD7AA39C332653B51EB9D1FB9CAF59FCFAFF9AFE", 1, 7} =>
      {857_342_907, 4_013_561_741, 2_198_832_665},
    {:producer, "2E80B966016539ACAF3158608745EAF3869C02012C0B5FAB2874099D4B79", 4, 3} =>
      {3_151_539_458, 2_263_723_341, 76_016_867},
    {:producer, "17A06A9E2B70472E0908AD7AA39C332653B51EB9D1FB9CAF59FCFAFF9AFE", 0, 2} =>
      {2_642_885_717, 1_114_380_995, 706_873_770},
    {:consumer, "BFBD0260BA02B81EFC02BF20D2ECDAEAA44490BD10F5744A0F5A3CB85CD2", 3,
     "SimulatorGroup1", 2} => {3_190_328_529, 134_922_643, 2_822_070_947},
    {:producer, "5333C7C3855A872BEF8F5812209D849A8336B78AB54D5A28AD298EF95107", 6, 7} =>
      {2_718_546_506, 190_685_317, 3_034_103_030},
    {:producer, "17A06A9E2B70472E0908AD7AA39C332653B51EB9D1FB9CAF59FCFAFF9AFE", 0, 0} =>
      {1_398_535_697, 1_860_961_127, 3_049_842_745},
    {:producer, "7EEAA041FCBFFCFB1DFE676EFA6CD64BC03784DF0C3326F1AB8451B97767", 7, 4} =>
      {2_082_388_711, 1_910_299_089, 825_916_569},
    {:producer, "935E08BA5C0045A4CA47E23A4679ADCCC6FEB6B6A8A2E79E3032AC9DCF4E", 10, 2} =>
      {240_092_218, 1_623_491_255, 1_226_929_193},
    {:producer, "2E80B966016539ACAF3158608745EAF3869C02012C0B5FAB2874099D4B79", 1, 6} =>
      {3_244_629_785, 4_079_309_852, 2_726_066_232},
    {:producer, "A442D3AE8CE988D98E73856B9E7B947F906683D5D35BBF022257B2747C30", 1, 3} =>
      {3_270_041_265, 1_601_175_466, 2_869_777_614},
    {:producer, "AFBBFA2030270377A2ECE63644380BEB3848C17B04B1DDFA7E4ACA98D62D", 1, 1} =>
      {1_341_066_487, 2_639_011_111, 2_986_960_731},
    {:producer, "935E08BA5C0045A4CA47E23A4679ADCCC6FEB6B6A8A2E79E3032AC9DCF4E", 4, 7} =>
      {4_135_233_591, 3_536_720_046, 3_072_152_124},
    {:producer, "A442D3AE8CE988D98E73856B9E7B947F906683D5D35BBF022257B2747C30", 6, 0} =>
      {2_527_723_761, 814_591_506, 1_149_648_601},
    {:producer, "7EEAA041FCBFFCFB1DFE676EFA6CD64BC03784DF0C3326F1AB8451B97767", 10, 7} =>
      {155_622_295, 3_066_685_761, 1_639_270_201},
    {:producer, "935E08BA5C0045A4CA47E23A4679ADCCC6FEB6B6A8A2E79E3032AC9DCF4E", 1, 7} =>
      {3_947_046_250, 946_066_537, 1_509_718_657},
    {:consumer, "935E08BA5C0045A4CA47E23A4679ADCCC6FEB6B6A8A2E79E3032AC9DCF4E", 5,
     "SimulatorGroup1", 1} => {1_672_357_814, 3_649_547_216, 527_520_415},
    {:producer, "BFBD0260BA02B81EFC02BF20D2ECDAEAA44490BD10F5744A0F5A3CB85CD2", 4, 1} =>
      {1_236_890_622, 2_773_422_603, 1_769_353_200},
    {:consumer, "7EEAA041FCBFFCFB1DFE676EFA6CD64BC03784DF0C3326F1AB8451B97767", 5,
     "SimulatorGroup1", 0} => {1_795_540_846, 1_149_774_321, 3_425_130_686},
    {:producer, "7EEAA041FCBFFCFB1DFE676EFA6CD64BC03784DF0C3326F1AB8451B97767", 6, 2} =>
      {1_278_707_181, 568_185_450, 4_031_645_710},
    {:consumer, "935E08BA5C0045A4CA47E23A4679ADCCC6FEB6B6A8A2E79E3032AC9DCF4E", 6,
     "SimulatorGroup1", 2} => {867_856_813, 1_706_356_069, 762_762_326},
    {:producer, "935E08BA5C0045A4CA47E23A4679ADCCC6FEB6B6A8A2E79E3032AC9DCF4E", 9, 6} =>
      {2_395_526_911, 1_901_693_679, 3_113_761_310},
    {:producer, "5333C7C3855A872BEF8F5812209D849A8336B78AB54D5A28AD298EF95107", 2, 5} =>
      {3_580_225_078, 500_614_848, 1_447_862_537},
    {:consumer, "935E08BA5C0045A4CA47E23A4679ADCCC6FEB6B6A8A2E79E3032AC9DCF4E", 0,
     "SimulatorGroup1", 1} => {3_513_824_792, 2_769_681_218, 1_942_872_399},
    {:producer, "2E80B966016539ACAF3158608745EAF3869C02012C0B5FAB2874099D4B79", 0, 3} =>
      {1_219_668_337, 3_421_864_102, 4_092_212_996},
    {:producer, "BFBD0260BA02B81EFC02BF20D2ECDAEAA44490BD10F5744A0F5A3CB85CD2", 1, 6} =>
      {3_772_422_068, 193_502_631, 2_913_216_918},
    {:consumer, "5333C7C3855A872BEF8F5812209D849A8336B78AB54D5A28AD298EF95107", 1,
     "SimulatorGroup1", 1} => {4_285_851_996, 1_690_206_612, 1_511_473_240},
    {:producer, "935E08BA5C0045A4CA47E23A4679ADCCC6FEB6B6A8A2E79E3032AC9DCF4E", 1, 2} =>
      {1_481_352_177, 120_059_738, 2_123_214_498},
    {:consumer, "BFBD0260BA02B81EFC02BF20D2ECDAEAA44490BD10F5744A0F5A3CB85CD2", 0,
     "SimulatorGroup1", 0} => {2_895_304_549, 4_013_478_208, 410_015_218}
  }
}