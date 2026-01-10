%Simulator.EngineConfig{
  clients: [Simulator.NormalClient, Simulator.TLSClient],
  topics: [
    %{partitions: 20, topic: "6DC3929629EBFF122B68BD089CC25AB166EB5E8F4DD0D9CAFD8DB4C1EFAA"},
    %{partitions: 20, topic: "207062696249B148CCA8395CCCD580F5A7A44A799BCB5D977174DDD8828B"},
    %{partitions: 20, topic: "1163127B48C51F8A38D3CAC696697EE1CB66C5B66EB4D0A21FEC8B7C3D4F"},
    %{partitions: 20, topic: "682335AB420E47AFAFDF6B5E14283449AF5B758D8C9E862267735E5F15CE"},
    %{partitions: 20, topic: "A99CAD7503CD9BBE9065FAD5FD1DA1A47A9A675F3CD802DC10514D186E4E"}
  ],
  topics_replication_factor: 1,
  consumer_groups: [
    %{name: "SimulatorGroup1", max_consumers: 1},
    %{name: "SimulatorGroup2", max_consumers: 1},
    %{name: "SimulatorGroup3", max_consumers: 1},
    %{name: "SimulatorGroup4", max_consumers: 1},
    %{name: "SimulatorGroup5", max_consumers: 1}
  ],
  consumer_group_configs: [
    [
      cg_mod: Simulator.Engine.Consumer.NormalClient1,
      isolation_level: :read_committed,
      committers_count: 1,
      fetch_strategy:
        {:exclusive,
         [
           request_timeout_ms: 5000,
           client_id: nil,
           isolation_level: :read_committed,
           max_bytes: 500_000,
           min_bytes: 1,
           max_wait_ms: 0
         ]},
      rebalance_timeout_ms: 30000,
      client: Simulator.NormalClient,
      topics: [
        [
          name: "6DC3929629EBFF122B68BD089CC25AB166EB5E8F4DD0D9CAFD8DB4C1EFAA",
          isolation_level: :read_committed,
          fetch_interval_ms: 30000,
          fetch_max_bytes: 100_000,
          handler_cooldown_ms: 0,
          handler_max_batch_size: 200,
          handler_max_unacked_commits: 0,
          max_queue_size: 20,
          offset_reset_policy: :earliest
        ],
        [
          name: "207062696249B148CCA8395CCCD580F5A7A44A799BCB5D977174DDD8828B",
          isolation_level: :read_committed,
          fetch_interval_ms: 5000,
          fetch_max_bytes: 5_000_000,
          handler_cooldown_ms: 0,
          handler_max_batch_size: 100,
          handler_max_unacked_commits: 10,
          offset_reset_policy: :latest
        ],
        [
          name: "1163127B48C51F8A38D3CAC696697EE1CB66C5B66EB4D0A21FEC8B7C3D4F",
          isolation_level: :read_uncommitted,
          fetch_interval_ms: 5000,
          fetch_max_bytes: 1_000_000,
          handler_cooldown_ms: 0,
          handler_max_batch_size: :dynamic,
          handler_max_unacked_commits: 0,
          offset_reset_policy: :latest
        ],
        [
          name: "682335AB420E47AFAFDF6B5E14283449AF5B758D8C9E862267735E5F15CE",
          isolation_level: :read_uncommitted,
          fetch_interval_ms: 5000,
          fetch_max_bytes: 1_000_000,
          handler_cooldown_ms: 0,
          handler_max_batch_size: :dynamic,
          handler_max_unacked_commits: 5,
          max_queue_size: 50,
          offset_reset_policy: :earliest
        ],
        [
          name: "A99CAD7503CD9BBE9065FAD5FD1DA1A47A9A675F3CD802DC10514D186E4E",
          isolation_level: :read_committed,
          fetch_interval_ms: 5000,
          fetch_max_bytes: 100_000,
          handler_cooldown_ms: 0,
          handler_max_batch_size: :dynamic,
          handler_max_unacked_commits: 0,
          offset_reset_policy: :latest
        ]
      ],
      group_name: "SimulatorGroup1"
    ],
    [
      cg_mod: Simulator.Engine.Consumer.NormalClient1,
      isolation_level: :read_committed,
      committers_count: 1,
      fetch_strategy:
        {:exclusive,
         [
           request_timeout_ms: 5000,
           client_id: nil,
           isolation_level: :read_committed,
           max_bytes: 500_000,
           min_bytes: 1,
           max_wait_ms: 0
         ]},
      rebalance_timeout_ms: 60000,
      client: Simulator.NormalClient,
      topics: [
        [
          name: "6DC3929629EBFF122B68BD089CC25AB166EB5E8F4DD0D9CAFD8DB4C1EFAA",
          isolation_level: :read_committed,
          fetch_interval_ms: 5000,
          fetch_max_bytes: 100_000,
          handler_cooldown_ms: 0,
          handler_max_batch_size: 200,
          handler_max_unacked_commits: 0,
          offset_reset_policy: :latest
        ],
        [
          name: "207062696249B148CCA8395CCCD580F5A7A44A799BCB5D977174DDD8828B",
          isolation_level: :read_committed,
          fetch_interval_ms: 5000,
          fetch_max_bytes: 5_000_000,
          handler_cooldown_ms: 0,
          handler_max_batch_size: 100,
          handler_max_unacked_commits: 0,
          max_queue_size: 20,
          offset_reset_policy: :latest
        ],
        [
          name: "1163127B48C51F8A38D3CAC696697EE1CB66C5B66EB4D0A21FEC8B7C3D4F",
          isolation_level: :read_committed,
          fetch_interval_ms: 5000,
          fetch_max_bytes: 500_000,
          handler_cooldown_ms: 0,
          handler_max_batch_size: 1000,
          handler_max_unacked_commits: 0,
          max_queue_size: 50,
          offset_reset_policy: :earliest
        ],
        [
          name: "682335AB420E47AFAFDF6B5E14283449AF5B758D8C9E862267735E5F15CE",
          isolation_level: :read_committed,
          fetch_interval_ms: 2500,
          fetch_max_bytes: 5_000_000,
          handler_cooldown_ms: 0,
          handler_max_batch_size: 1000,
          handler_max_unacked_commits: 0,
          offset_reset_policy: :earliest
        ],
        [
          name: "A99CAD7503CD9BBE9065FAD5FD1DA1A47A9A675F3CD802DC10514D186E4E",
          isolation_level: :read_committed,
          fetch_interval_ms: 1000,
          fetch_max_bytes: 5_000_000,
          handler_cooldown_ms: 0,
          handler_max_batch_size: 100,
          handler_max_unacked_commits: 0,
          offset_reset_policy: :latest
        ]
      ],
      group_name: "SimulatorGroup2"
    ],
    [
      cg_mod: Simulator.Engine.Consumer.NormalClient1,
      isolation_level: :read_committed,
      committers_count: 1,
      fetch_strategy:
        {:exclusive,
         [
           request_timeout_ms: 5000,
           client_id: nil,
           isolation_level: :read_committed,
           max_bytes: 500_000,
           min_bytes: 1,
           max_wait_ms: 0
         ]},
      rebalance_timeout_ms: 30000,
      client: Simulator.NormalClient,
      topics: [
        [
          name: "6DC3929629EBFF122B68BD089CC25AB166EB5E8F4DD0D9CAFD8DB4C1EFAA",
          isolation_level: :read_committed,
          fetch_interval_ms: 30000,
          fetch_max_bytes: 5_000_000,
          handler_cooldown_ms: 0,
          handler_max_batch_size: 1000,
          handler_max_unacked_commits: 10,
          max_queue_size: 50,
          offset_reset_policy: :latest
        ],
        [
          name: "207062696249B148CCA8395CCCD580F5A7A44A799BCB5D977174DDD8828B",
          isolation_level: :read_committed,
          fetch_strategy:
            {:exclusive,
             [
               request_timeout_ms: 5000,
               client_id: nil,
               isolation_level: :read_committed,
               max_bytes: 1_000_000,
               min_bytes: 1,
               max_wait_ms: 500
             ]},
          fetch_interval_ms: 10000,
          fetch_max_bytes: 500_000,
          handler_cooldown_ms: 0,
          handler_max_batch_size: :dynamic,
          handler_max_unacked_commits: 0,
          max_queue_size: 10,
          offset_reset_policy: :latest
        ],
        [
          name: "1163127B48C51F8A38D3CAC696697EE1CB66C5B66EB4D0A21FEC8B7C3D4F",
          isolation_level: :read_committed,
          fetch_interval_ms: 5000,
          fetch_max_bytes: 500_000,
          handler_cooldown_ms: 0,
          handler_max_batch_size: 100,
          handler_max_unacked_commits: 0,
          offset_reset_policy: :latest
        ],
        [
          name: "682335AB420E47AFAFDF6B5E14283449AF5B758D8C9E862267735E5F15CE",
          isolation_level: :read_committed,
          fetch_strategy:
            {:exclusive,
             [
               request_timeout_ms: 3000,
               client_id: nil,
               isolation_level: :read_committed,
               max_bytes: 500_000,
               min_bytes: 1,
               max_wait_ms: 0
             ]},
          fetch_interval_ms: 5000,
          fetch_max_bytes: 100_000,
          handler_cooldown_ms: 0,
          handler_max_batch_size: 200,
          handler_max_unacked_commits: 0,
          max_queue_size: 50,
          offset_reset_policy: :earliest
        ],
        [
          name: "A99CAD7503CD9BBE9065FAD5FD1DA1A47A9A675F3CD802DC10514D186E4E",
          isolation_level: :read_committed,
          fetch_interval_ms: 2500,
          fetch_max_bytes: 2_000_000,
          handler_cooldown_ms: 0,
          handler_max_batch_size: :dynamic,
          handler_max_unacked_commits: 0,
          max_queue_size: 10,
          offset_reset_policy: :latest
        ]
      ],
      group_name: "SimulatorGroup3"
    ],
    [
      cg_mod: Simulator.Engine.Consumer.TLSClient1,
      isolation_level: :read_committed,
      committers_count: 1,
      fetch_strategy:
        {:exclusive,
         [
           request_timeout_ms: 30000,
           client_id: nil,
           isolation_level: :read_committed,
           max_bytes: 500_000,
           min_bytes: 1,
           max_wait_ms: 500
         ]},
      rebalance_timeout_ms: 10000,
      client: Simulator.TLSClient,
      topics: [
        [
          name: "6DC3929629EBFF122B68BD089CC25AB166EB5E8F4DD0D9CAFD8DB4C1EFAA",
          isolation_level: :read_committed,
          fetch_interval_ms: 2500,
          fetch_max_bytes: 1_000_000,
          handler_cooldown_ms: 0,
          handler_max_batch_size: 1000,
          handler_max_unacked_commits: 0,
          offset_reset_policy: :latest
        ],
        [
          name: "207062696249B148CCA8395CCCD580F5A7A44A799BCB5D977174DDD8828B",
          isolation_level: :read_committed,
          fetch_interval_ms: 1000,
          fetch_max_bytes: 1_000_000,
          handler_cooldown_ms: 0,
          handler_max_batch_size: :dynamic,
          handler_max_unacked_commits: 0,
          max_queue_size: 20,
          offset_reset_policy: :latest
        ],
        [
          name: "1163127B48C51F8A38D3CAC696697EE1CB66C5B66EB4D0A21FEC8B7C3D4F",
          isolation_level: :read_committed,
          fetch_interval_ms: 2500,
          fetch_max_bytes: 500_000,
          handler_cooldown_ms: 0,
          handler_max_batch_size: :dynamic,
          handler_max_unacked_commits: 10,
          max_queue_size: 50,
          offset_reset_policy: :latest
        ],
        [
          name: "682335AB420E47AFAFDF6B5E14283449AF5B758D8C9E862267735E5F15CE",
          isolation_level: :read_uncommitted,
          fetch_interval_ms: 30000,
          fetch_max_bytes: 1_000_000,
          handler_cooldown_ms: 0,
          handler_max_batch_size: :dynamic,
          handler_max_unacked_commits: 5,
          max_queue_size: 20,
          offset_reset_policy: :latest
        ],
        [
          name: "A99CAD7503CD9BBE9065FAD5FD1DA1A47A9A675F3CD802DC10514D186E4E",
          isolation_level: :read_committed,
          fetch_interval_ms: 5000,
          fetch_max_bytes: 500_000,
          handler_cooldown_ms: 0,
          handler_max_batch_size: 200,
          handler_max_unacked_commits: 0,
          offset_reset_policy: :latest
        ]
      ],
      group_name: "SimulatorGroup4"
    ],
    [
      cg_mod: Simulator.Engine.Consumer.NormalClient1,
      isolation_level: :read_committed,
      committers_count: 1,
      fetch_strategy:
        {:exclusive,
         [
           request_timeout_ms: 5000,
           client_id: nil,
           isolation_level: :read_committed,
           max_bytes: 500_000,
           min_bytes: 1,
           max_wait_ms: 0
         ]},
      rebalance_timeout_ms: 30000,
      client: Simulator.NormalClient,
      topics: [
        [
          name: "6DC3929629EBFF122B68BD089CC25AB166EB5E8F4DD0D9CAFD8DB4C1EFAA",
          isolation_level: :read_committed,
          fetch_interval_ms: 5000,
          fetch_max_bytes: 5_000_000,
          handler_cooldown_ms: 0,
          handler_max_batch_size: :dynamic,
          handler_max_unacked_commits: 5,
          offset_reset_policy: :latest
        ],
        [
          name: "207062696249B148CCA8395CCCD580F5A7A44A799BCB5D977174DDD8828B",
          isolation_level: :read_committed,
          fetch_strategy:
            {:exclusive,
             [
               request_timeout_ms: 30000,
               client_id: nil,
               isolation_level: :read_committed,
               max_bytes: 500_000,
               min_bytes: 1,
               max_wait_ms: 0
             ]},
          fetch_interval_ms: 5000,
          fetch_max_bytes: 1_000_000,
          handler_cooldown_ms: 0,
          handler_max_batch_size: :dynamic,
          handler_max_unacked_commits: 0,
          offset_reset_policy: :latest
        ],
        [
          name: "1163127B48C51F8A38D3CAC696697EE1CB66C5B66EB4D0A21FEC8B7C3D4F",
          isolation_level: :read_committed,
          fetch_interval_ms: 5000,
          fetch_max_bytes: 2_000_000,
          handler_cooldown_ms: 0,
          handler_max_batch_size: :dynamic,
          handler_max_unacked_commits: 0,
          offset_reset_policy: :latest
        ],
        [
          name: "682335AB420E47AFAFDF6B5E14283449AF5B758D8C9E862267735E5F15CE",
          isolation_level: :read_uncommitted,
          fetch_interval_ms: 5000,
          fetch_max_bytes: 2_000_000,
          handler_cooldown_ms: 0,
          handler_max_batch_size: 100,
          handler_max_unacked_commits: 0,
          max_queue_size: 10,
          offset_reset_policy: :latest
        ],
        [
          name: "A99CAD7503CD9BBE9065FAD5FD1DA1A47A9A675F3CD802DC10514D186E4E",
          isolation_level: :read_uncommitted,
          fetch_interval_ms: 30000,
          fetch_max_bytes: 1_000_000,
          handler_cooldown_ms: 0,
          handler_max_batch_size: :dynamic,
          handler_max_unacked_commits: 0,
          offset_reset_policy: :latest
        ]
      ],
      group_name: "SimulatorGroup5"
    ]
  ],
  producer_max_rps: 10,
  producer_concurrency: 25,
  producer_loop_interval_ms: 5000,
  record_value_bytes: 10,
  record_key_bytes: 128,
  invariants_check_interval_ms: 2000,
  lag_warning_multiplier: 5
}
