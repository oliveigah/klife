%Simulator.EngineConfig{
  clients: [Simulator.NormalClient, Simulator.TLSClient],
  topics: [
    %{topic: "D3B5DC8E6FA26ACE24AB60A9EFFA3699EE4284A73F5F750C6B29F3B8E093", partitions: 1},
    %{topic: "5F95FCFA4AC6992AEAFC791D92E3FB08DA91B2926310DE137DA27577E8A0", partitions: 1},
    %{topic: "7722480ABC69385FA9DC75AA1AEEBD1D5006B386292F68DE3302E4C2A4A1", partitions: 1},
    %{topic: "FBCC0DDC89898EB5EE9DF11502EEDA5920F8D9A7B6D9CFB816D5985A9143", partitions: 1},
    %{topic: "31F4226252DBD1DB7F67B8167932E2ED4B7118D1CA3DA7AB5EA40E8D87DA", partitions: 1}
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
      rebalance_timeout_ms: 10000,
      client: Simulator.NormalClient,
      topics: [
        [
          name: "D3B5DC8E6FA26ACE24AB60A9EFFA3699EE4284A73F5F750C6B29F3B8E093",
          isolation_level: :read_committed,
          fetch_interval_ms: 30000,
          fetch_max_bytes: 1_000_000,
          handler_cooldown_ms: 0,
          handler_max_batch_size: 100,
          handler_max_unacked_commits: 0,
          max_queue_size: 50,
          offset_reset_policy: :earliest
        ],
        [
          name: "5F95FCFA4AC6992AEAFC791D92E3FB08DA91B2926310DE137DA27577E8A0",
          isolation_level: :read_committed,
          fetch_interval_ms: 5000,
          fetch_max_bytes: 1_000_000,
          handler_cooldown_ms: 0,
          handler_max_batch_size: 100,
          handler_max_unacked_commits: 0,
          max_queue_size: 10,
          offset_reset_policy: :latest
        ],
        [
          name: "7722480ABC69385FA9DC75AA1AEEBD1D5006B386292F68DE3302E4C2A4A1",
          isolation_level: :read_committed,
          fetch_interval_ms: 2500,
          fetch_max_bytes: 1_000_000,
          handler_cooldown_ms: 0,
          handler_max_batch_size: :dynamic,
          handler_max_unacked_commits: 0,
          offset_reset_policy: :latest
        ],
        [
          name: "FBCC0DDC89898EB5EE9DF11502EEDA5920F8D9A7B6D9CFB816D5985A9143",
          isolation_level: :read_committed,
          fetch_interval_ms: 1000,
          fetch_max_bytes: 1_000_000,
          handler_cooldown_ms: 0,
          handler_max_batch_size: :dynamic,
          handler_max_unacked_commits: 0,
          offset_reset_policy: :latest
        ],
        [
          name: "31F4226252DBD1DB7F67B8167932E2ED4B7118D1CA3DA7AB5EA40E8D87DA",
          isolation_level: :read_committed,
          fetch_interval_ms: 5000,
          fetch_max_bytes: 1_000_000,
          handler_cooldown_ms: 0,
          handler_max_batch_size: 200,
          handler_max_unacked_commits: 0,
          max_queue_size: 50,
          offset_reset_policy: :latest
        ]
      ],
      group_name: "SimulatorGroup1"
    ],
    [
      cg_mod: Simulator.Engine.Consumer.TLSClient1,
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
      client: Simulator.TLSClient,
      topics: [
        [
          name: "D3B5DC8E6FA26ACE24AB60A9EFFA3699EE4284A73F5F750C6B29F3B8E093",
          isolation_level: :read_uncommitted,
          fetch_interval_ms: 30000,
          fetch_max_bytes: 1_000_000,
          handler_cooldown_ms: 0,
          handler_max_batch_size: :dynamic,
          handler_max_unacked_commits: 0,
          offset_reset_policy: :latest
        ],
        [
          name: "5F95FCFA4AC6992AEAFC791D92E3FB08DA91B2926310DE137DA27577E8A0",
          isolation_level: :read_committed,
          fetch_interval_ms: 5000,
          fetch_max_bytes: 1_000_000,
          handler_cooldown_ms: 0,
          handler_max_batch_size: 1000,
          handler_max_unacked_commits: 0,
          offset_reset_policy: :earliest
        ],
        [
          name: "7722480ABC69385FA9DC75AA1AEEBD1D5006B386292F68DE3302E4C2A4A1",
          isolation_level: :read_committed,
          fetch_interval_ms: 5000,
          fetch_max_bytes: 1_000_000,
          handler_cooldown_ms: 0,
          handler_max_batch_size: :dynamic,
          handler_max_unacked_commits: 0,
          max_queue_size: 50,
          offset_reset_policy: :latest
        ],
        [
          name: "FBCC0DDC89898EB5EE9DF11502EEDA5920F8D9A7B6D9CFB816D5985A9143",
          isolation_level: :read_committed,
          fetch_strategy:
            {:exclusive,
             [
               request_timeout_ms: 3000,
               client_id: nil,
               isolation_level: :read_committed,
               max_bytes: 500_000,
               min_bytes: 1,
               max_wait_ms: 100
             ]},
          fetch_interval_ms: 5000,
          fetch_max_bytes: 1_000_000,
          handler_cooldown_ms: 0,
          handler_max_batch_size: 1000,
          handler_max_unacked_commits: 0,
          offset_reset_policy: :earliest
        ],
        [
          name: "31F4226252DBD1DB7F67B8167932E2ED4B7118D1CA3DA7AB5EA40E8D87DA",
          isolation_level: :read_committed,
          fetch_interval_ms: 10000,
          fetch_max_bytes: 1_000_000,
          handler_cooldown_ms: 0,
          handler_max_batch_size: :dynamic,
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
      rebalance_timeout_ms: 60000,
      client: Simulator.NormalClient,
      topics: [
        [
          name: "D3B5DC8E6FA26ACE24AB60A9EFFA3699EE4284A73F5F750C6B29F3B8E093",
          isolation_level: :read_committed,
          fetch_interval_ms: 10000,
          fetch_max_bytes: 1_000_000,
          handler_cooldown_ms: 0,
          handler_max_batch_size: :dynamic,
          handler_max_unacked_commits: 0,
          max_queue_size: 10,
          offset_reset_policy: :latest
        ],
        [
          name: "5F95FCFA4AC6992AEAFC791D92E3FB08DA91B2926310DE137DA27577E8A0",
          isolation_level: :read_committed,
          fetch_interval_ms: 30000,
          fetch_max_bytes: 1_000_000,
          handler_cooldown_ms: 0,
          handler_max_batch_size: 200,
          handler_max_unacked_commits: 0,
          offset_reset_policy: :latest
        ],
        [
          name: "7722480ABC69385FA9DC75AA1AEEBD1D5006B386292F68DE3302E4C2A4A1",
          isolation_level: :read_committed,
          fetch_interval_ms: 5000,
          fetch_max_bytes: 1_000_000,
          handler_cooldown_ms: 0,
          handler_max_batch_size: 200,
          handler_max_unacked_commits: 0,
          offset_reset_policy: :latest
        ],
        [
          name: "FBCC0DDC89898EB5EE9DF11502EEDA5920F8D9A7B6D9CFB816D5985A9143",
          isolation_level: :read_committed,
          fetch_interval_ms: 5000,
          fetch_max_bytes: 1_000_000,
          handler_cooldown_ms: 0,
          handler_max_batch_size: :dynamic,
          handler_max_unacked_commits: 0,
          offset_reset_policy: :latest
        ],
        [
          name: "31F4226252DBD1DB7F67B8167932E2ED4B7118D1CA3DA7AB5EA40E8D87DA",
          isolation_level: :read_committed,
          fetch_strategy:
            {:exclusive,
             [
               request_timeout_ms: 10000,
               client_id: nil,
               isolation_level: :read_committed,
               max_bytes: 250_000,
               min_bytes: 1,
               max_wait_ms: 0
             ]},
          fetch_interval_ms: 10000,
          fetch_max_bytes: 1_000_000,
          handler_cooldown_ms: 0,
          handler_max_batch_size: 1000,
          handler_max_unacked_commits: 0,
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
           request_timeout_ms: 5000,
           client_id: nil,
           isolation_level: :read_committed,
           max_bytes: 500_000,
           min_bytes: 1,
           max_wait_ms: 0
         ]},
      rebalance_timeout_ms: 10000,
      client: Simulator.TLSClient,
      topics: [
        [
          name: "D3B5DC8E6FA26ACE24AB60A9EFFA3699EE4284A73F5F750C6B29F3B8E093",
          isolation_level: :read_committed,
          fetch_interval_ms: 5000,
          fetch_max_bytes: 1_000_000,
          handler_cooldown_ms: 0,
          handler_max_batch_size: 100,
          handler_max_unacked_commits: 0,
          max_queue_size: 50,
          offset_reset_policy: :latest
        ],
        [
          name: "5F95FCFA4AC6992AEAFC791D92E3FB08DA91B2926310DE137DA27577E8A0",
          isolation_level: :read_committed,
          fetch_interval_ms: 5000,
          fetch_max_bytes: 1_000_000,
          handler_cooldown_ms: 0,
          handler_max_batch_size: :dynamic,
          handler_max_unacked_commits: 0,
          offset_reset_policy: :latest
        ],
        [
          name: "7722480ABC69385FA9DC75AA1AEEBD1D5006B386292F68DE3302E4C2A4A1",
          isolation_level: :read_committed,
          fetch_strategy:
            {:exclusive,
             [
               request_timeout_ms: 5000,
               client_id: nil,
               isolation_level: :read_committed,
               max_bytes: 250_000,
               min_bytes: 1,
               max_wait_ms: 100
             ]},
          fetch_interval_ms: 10000,
          fetch_max_bytes: 1_000_000,
          handler_cooldown_ms: 0,
          handler_max_batch_size: :dynamic,
          handler_max_unacked_commits: 0,
          offset_reset_policy: :latest
        ],
        [
          name: "FBCC0DDC89898EB5EE9DF11502EEDA5920F8D9A7B6D9CFB816D5985A9143",
          isolation_level: :read_uncommitted,
          fetch_interval_ms: 5000,
          fetch_max_bytes: 1_000_000,
          handler_cooldown_ms: 0,
          handler_max_batch_size: :dynamic,
          handler_max_unacked_commits: 0,
          offset_reset_policy: :latest
        ],
        [
          name: "31F4226252DBD1DB7F67B8167932E2ED4B7118D1CA3DA7AB5EA40E8D87DA",
          isolation_level: :read_uncommitted,
          fetch_interval_ms: 5000,
          fetch_max_bytes: 1_000_000,
          handler_cooldown_ms: 0,
          handler_max_batch_size: 200,
          handler_max_unacked_commits: 0,
          offset_reset_policy: :earliest
        ]
      ],
      group_name: "SimulatorGroup4"
    ],
    [
      cg_mod: Simulator.Engine.Consumer.TLSClient1,
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
           max_wait_ms: 500
         ]},
      rebalance_timeout_ms: 20000,
      client: Simulator.TLSClient,
      topics: [
        [
          name: "D3B5DC8E6FA26ACE24AB60A9EFFA3699EE4284A73F5F750C6B29F3B8E093",
          isolation_level: :read_committed,
          fetch_interval_ms: 5000,
          fetch_max_bytes: 1_000_000,
          handler_cooldown_ms: 0,
          handler_max_batch_size: 200,
          handler_max_unacked_commits: 0,
          offset_reset_policy: :latest
        ],
        [
          name: "5F95FCFA4AC6992AEAFC791D92E3FB08DA91B2926310DE137DA27577E8A0",
          isolation_level: :read_committed,
          fetch_interval_ms: 5000,
          fetch_max_bytes: 1_000_000,
          handler_cooldown_ms: 0,
          handler_max_batch_size: :dynamic,
          handler_max_unacked_commits: 0,
          max_queue_size: 10,
          offset_reset_policy: :latest
        ],
        [
          name: "7722480ABC69385FA9DC75AA1AEEBD1D5006B386292F68DE3302E4C2A4A1",
          isolation_level: :read_committed,
          fetch_interval_ms: 2500,
          fetch_max_bytes: 1_000_000,
          handler_cooldown_ms: 0,
          handler_max_batch_size: :dynamic,
          handler_max_unacked_commits: 0,
          offset_reset_policy: :latest
        ],
        [
          name: "FBCC0DDC89898EB5EE9DF11502EEDA5920F8D9A7B6D9CFB816D5985A9143",
          isolation_level: :read_committed,
          fetch_interval_ms: 2500,
          fetch_max_bytes: 1_000_000,
          handler_cooldown_ms: 0,
          handler_max_batch_size: 1000,
          handler_max_unacked_commits: 0,
          offset_reset_policy: :latest
        ],
        [
          name: "31F4226252DBD1DB7F67B8167932E2ED4B7118D1CA3DA7AB5EA40E8D87DA",
          isolation_level: :read_committed,
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
          fetch_interval_ms: 5000,
          fetch_max_bytes: 1_000_000,
          handler_cooldown_ms: 0,
          handler_max_batch_size: 1000,
          handler_max_unacked_commits: 0,
          offset_reset_policy: :latest
        ]
      ],
      group_name: "SimulatorGroup5"
    ]
  ],
  producer_max_rps: 50,
  producer_concurrency: 5,
  producer_loop_interval_ms: 1000,
  record_value_bytes: 10,
  record_key_bytes: 64,
  invariants_check_interval_ms: 5000,
  lag_warning_multiplier: 5
}
