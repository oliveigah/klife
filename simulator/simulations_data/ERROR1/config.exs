%Simulator.EngineConfig{
  clients: [Simulator.NormalClient, Simulator.TLSClient],
  topics: [
    %{topic: "5B9C2873DBCE5875B0A8E59AA4EF2CC29B951ED8BA4C57265BD31BB11D10", partitions: 20},
    %{topic: "040BED68F9F276B0951092957BFA07A94C3307AC62DD90058097A2A04122", partitions: 20},
    %{topic: "539A81A910AAF349E8EA597771CF3B622DA24EFC324A1C2DD0F105AF7405", partitions: 1},
    %{topic: "B5E9D2FFCAAE7BBEE84E9279A7B9DE81D59E65B59663D55C5E20DFEC592C", partitions: 20},
    %{topic: "A19F1C6483D6D9EB891B1E1306AA1AEE89742C6BB4D4B388FA2F4481E9E7", partitions: 20},
    %{topic: "3DFF90B9A4D146917DB5A53CE1D80AE3D77F904E5DA09F6275BC247EF94E", partitions: 1},
    %{topic: "18FAA84C74D8DD647CA5AF4E85ED384B81DA006994F59C51ADDA7C56BF3D", partitions: 10},
    %{topic: "1D8B632DAF3B60F25FCA0B7048F91E26A27E5D870FB4764788071FE998BD", partitions: 15},
    %{topic: "772ABE130905A7F5492A594C7A4CC8D2A899C9EDEA07E771E5EB17CE6665", partitions: 20},
    %{topic: "F9C4AECEE20E29546C58DF829B8023BAD97049A871DA17A4B9344FB2AB3D", partitions: 15}
  ],
  topics_replication_factor: 3,
  consumer_groups: [
    %{name: "SimulatorGroup1", max_consumers: 1},
    %{name: "SimulatorGroup2", max_consumers: 1},
    %{name: "SimulatorGroup3", max_consumers: 1},
    %{name: "SimulatorGroup4", max_consumers: 1},
    %{name: "SimulatorGroup5", max_consumers: 1}
  ],
  consumer_group_configs: [
    [
      cg_mod: Simulator.Engine.Consumer.TLSClient1,
      isolation_level: :read_committed,
      committers_count: 1,
      rebalance_timeout_ms: 30000,
      client: Simulator.TLSClient,
      topics: [
        [
          name: "5B9C2873DBCE5875B0A8E59AA4EF2CC29B951ED8BA4C57265BD31BB11D10",
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
          handler_max_unacked_commits: 0,
          handler_max_batch_size: 100,
          offset_reset_policy: :latest,
          fetch_max_bytes: 1_000_000,
          max_queue_size: 50,
          fetch_interval_ms: 5000,
          handler_cooldown_ms: 0,
          isolation_level: :read_uncommitted
        ],
        [
          name: "040BED68F9F276B0951092957BFA07A94C3307AC62DD90058097A2A04122",
          handler_max_unacked_commits: 0,
          handler_max_batch_size: :dynamic,
          offset_reset_policy: :latest,
          fetch_max_bytes: 1_000_000,
          max_queue_size: 50,
          fetch_interval_ms: 1000,
          handler_cooldown_ms: 0,
          isolation_level: :read_committed
        ],
        [
          name: "539A81A910AAF349E8EA597771CF3B622DA24EFC324A1C2DD0F105AF7405",
          handler_max_unacked_commits: 0,
          handler_max_batch_size: :dynamic,
          offset_reset_policy: :latest,
          fetch_max_bytes: 1_000_000,
          fetch_interval_ms: 5000,
          handler_cooldown_ms: 0,
          isolation_level: :read_committed
        ],
        [
          name: "B5E9D2FFCAAE7BBEE84E9279A7B9DE81D59E65B59663D55C5E20DFEC592C",
          handler_max_unacked_commits: 0,
          handler_max_batch_size: 1000,
          offset_reset_policy: :latest,
          fetch_max_bytes: 1_000_000,
          max_queue_size: 10,
          fetch_interval_ms: 5000,
          handler_cooldown_ms: 0,
          isolation_level: :read_committed
        ],
        [
          name: "A19F1C6483D6D9EB891B1E1306AA1AEE89742C6BB4D4B388FA2F4481E9E7",
          handler_max_unacked_commits: 0,
          handler_max_batch_size: :dynamic,
          offset_reset_policy: :latest,
          fetch_max_bytes: 1_000_000,
          fetch_interval_ms: 2500,
          handler_cooldown_ms: 0,
          isolation_level: :read_committed
        ],
        [
          name: "3DFF90B9A4D146917DB5A53CE1D80AE3D77F904E5DA09F6275BC247EF94E",
          handler_max_unacked_commits: 0,
          handler_max_batch_size: 200,
          offset_reset_policy: :latest,
          fetch_max_bytes: 1_000_000,
          fetch_interval_ms: 5000,
          handler_cooldown_ms: 0,
          isolation_level: :read_committed
        ],
        [
          name: "18FAA84C74D8DD647CA5AF4E85ED384B81DA006994F59C51ADDA7C56BF3D",
          fetch_strategy: {:shared, :klife_default_fetcher},
          handler_max_unacked_commits: 0,
          handler_max_batch_size: 100,
          offset_reset_policy: :latest,
          fetch_max_bytes: 1_000_000,
          max_queue_size: 50,
          fetch_interval_ms: 5000,
          handler_cooldown_ms: 0,
          isolation_level: :read_uncommitted
        ],
        [
          name: "1D8B632DAF3B60F25FCA0B7048F91E26A27E5D870FB4764788071FE998BD",
          fetch_strategy:
            {:exclusive,
             [
               request_timeout_ms: 5000,
               client_id: nil,
               isolation_level: :read_committed,
               max_bytes: 500_000,
               min_bytes: 1,
               max_wait_ms: 1000
             ]},
          handler_max_unacked_commits: 0,
          handler_max_batch_size: 200,
          offset_reset_policy: :latest,
          fetch_max_bytes: 1_000_000,
          fetch_interval_ms: 2500,
          handler_cooldown_ms: 0,
          isolation_level: :read_committed
        ],
        [
          name: "772ABE130905A7F5492A594C7A4CC8D2A899C9EDEA07E771E5EB17CE6665",
          fetch_strategy:
            {:exclusive,
             [
               request_timeout_ms: 5000,
               client_id: nil,
               isolation_level: :read_uncommitted,
               max_bytes: 500_000,
               min_bytes: 1,
               max_wait_ms: 0
             ]},
          handler_max_unacked_commits: 0,
          handler_max_batch_size: :dynamic,
          offset_reset_policy: :latest,
          fetch_max_bytes: 1_000_000,
          fetch_interval_ms: 5000,
          handler_cooldown_ms: 0,
          isolation_level: :read_committed
        ],
        [
          name: "F9C4AECEE20E29546C58DF829B8023BAD97049A871DA17A4B9344FB2AB3D",
          handler_max_unacked_commits: 0,
          handler_max_batch_size: :dynamic,
          offset_reset_policy: :latest,
          fetch_max_bytes: 1_000_000,
          fetch_interval_ms: 5000,
          handler_cooldown_ms: 0,
          isolation_level: :read_committed
        ]
      ],
      group_name: "SimulatorGroup1",
      fetch_strategy: {:shared, :klife_default_fetcher}
    ],
    [
      cg_mod: Simulator.Engine.Consumer.NormalClient1,
      isolation_level: :read_committed,
      committers_count: 1,
      rebalance_timeout_ms: 10000,
      client: Simulator.NormalClient,
      topics: [
        [
          name: "5B9C2873DBCE5875B0A8E59AA4EF2CC29B951ED8BA4C57265BD31BB11D10",
          handler_max_unacked_commits: 0,
          handler_max_batch_size: 200,
          offset_reset_policy: :latest,
          fetch_max_bytes: 1_000_000,
          max_queue_size: 50,
          fetch_interval_ms: 1000,
          handler_cooldown_ms: 0,
          isolation_level: :read_committed
        ],
        [
          name: "040BED68F9F276B0951092957BFA07A94C3307AC62DD90058097A2A04122",
          fetch_strategy:
            {:exclusive,
             [
               request_timeout_ms: 3000,
               client_id: nil,
               isolation_level: :read_committed,
               max_bytes: 1_000_000,
               min_bytes: 1,
               max_wait_ms: 0
             ]},
          handler_max_unacked_commits: 0,
          handler_max_batch_size: 200,
          offset_reset_policy: :earliest,
          fetch_max_bytes: 1_000_000,
          fetch_interval_ms: 2500,
          handler_cooldown_ms: 0,
          isolation_level: :read_committed
        ],
        [
          name: "539A81A910AAF349E8EA597771CF3B622DA24EFC324A1C2DD0F105AF7405",
          handler_max_unacked_commits: 0,
          handler_max_batch_size: 1000,
          offset_reset_policy: :latest,
          fetch_max_bytes: 1_000_000,
          fetch_interval_ms: 10000,
          handler_cooldown_ms: 0,
          isolation_level: :read_committed
        ],
        [
          name: "B5E9D2FFCAAE7BBEE84E9279A7B9DE81D59E65B59663D55C5E20DFEC592C",
          handler_max_unacked_commits: 0,
          handler_max_batch_size: 100,
          offset_reset_policy: :latest,
          fetch_max_bytes: 1_000_000,
          fetch_interval_ms: 30000,
          handler_cooldown_ms: 0,
          isolation_level: :read_committed
        ],
        [
          name: "A19F1C6483D6D9EB891B1E1306AA1AEE89742C6BB4D4B388FA2F4481E9E7",
          handler_max_unacked_commits: 0,
          handler_max_batch_size: 100,
          offset_reset_policy: :latest,
          fetch_max_bytes: 1_000_000,
          fetch_interval_ms: 5000,
          handler_cooldown_ms: 0,
          isolation_level: :read_committed
        ],
        [
          name: "3DFF90B9A4D146917DB5A53CE1D80AE3D77F904E5DA09F6275BC247EF94E",
          handler_max_unacked_commits: 0,
          handler_max_batch_size: 200,
          offset_reset_policy: :latest,
          fetch_max_bytes: 1_000_000,
          max_queue_size: 20,
          fetch_interval_ms: 5000,
          handler_cooldown_ms: 0,
          isolation_level: :read_uncommitted
        ],
        [
          name: "18FAA84C74D8DD647CA5AF4E85ED384B81DA006994F59C51ADDA7C56BF3D",
          handler_max_unacked_commits: 0,
          handler_max_batch_size: :dynamic,
          offset_reset_policy: :latest,
          fetch_max_bytes: 1_000_000,
          fetch_interval_ms: 5000,
          handler_cooldown_ms: 0,
          isolation_level: :read_committed
        ],
        [
          name: "1D8B632DAF3B60F25FCA0B7048F91E26A27E5D870FB4764788071FE998BD",
          fetch_strategy:
            {:exclusive,
             [
               request_timeout_ms: 5000,
               client_id: nil,
               isolation_level: :read_committed,
               max_bytes: 500_000,
               min_bytes: 1,
               max_wait_ms: 1000
             ]},
          handler_max_unacked_commits: 0,
          handler_max_batch_size: 200,
          offset_reset_policy: :earliest,
          fetch_max_bytes: 1_000_000,
          fetch_interval_ms: 5000,
          handler_cooldown_ms: 0,
          isolation_level: :read_committed
        ],
        [
          name: "772ABE130905A7F5492A594C7A4CC8D2A899C9EDEA07E771E5EB17CE6665",
          handler_max_unacked_commits: 0,
          handler_max_batch_size: 100,
          offset_reset_policy: :latest,
          fetch_max_bytes: 1_000_000,
          fetch_interval_ms: 5000,
          handler_cooldown_ms: 0,
          isolation_level: :read_committed
        ],
        [
          name: "F9C4AECEE20E29546C58DF829B8023BAD97049A871DA17A4B9344FB2AB3D",
          fetch_strategy: {:shared, :klife_default_fetcher},
          handler_max_unacked_commits: 0,
          handler_max_batch_size: 200,
          offset_reset_policy: :latest,
          fetch_max_bytes: 1_000_000,
          max_queue_size: 20,
          fetch_interval_ms: 10000,
          handler_cooldown_ms: 0,
          isolation_level: :read_committed
        ]
      ],
      group_name: "SimulatorGroup2",
      fetch_strategy: {:shared, :klife_default_fetcher}
    ],
    [
      cg_mod: Simulator.Engine.Consumer.TLSClient1,
      isolation_level: :read_committed,
      committers_count: 1,
      rebalance_timeout_ms: 30000,
      client: Simulator.TLSClient,
      topics: [
        [
          name: "5B9C2873DBCE5875B0A8E59AA4EF2CC29B951ED8BA4C57265BD31BB11D10",
          handler_max_unacked_commits: 0,
          handler_max_batch_size: 200,
          offset_reset_policy: :latest,
          fetch_max_bytes: 1_000_000,
          fetch_interval_ms: 5000,
          handler_cooldown_ms: 0,
          isolation_level: :read_uncommitted
        ],
        [
          name: "040BED68F9F276B0951092957BFA07A94C3307AC62DD90058097A2A04122",
          handler_max_unacked_commits: 0,
          handler_max_batch_size: 200,
          offset_reset_policy: :latest,
          fetch_max_bytes: 1_000_000,
          fetch_interval_ms: 1000,
          handler_cooldown_ms: 0,
          isolation_level: :read_committed
        ],
        [
          name: "539A81A910AAF349E8EA597771CF3B622DA24EFC324A1C2DD0F105AF7405",
          handler_max_unacked_commits: 0,
          handler_max_batch_size: 100,
          offset_reset_policy: :latest,
          fetch_max_bytes: 1_000_000,
          fetch_interval_ms: 5000,
          handler_cooldown_ms: 0,
          isolation_level: :read_committed
        ],
        [
          name: "B5E9D2FFCAAE7BBEE84E9279A7B9DE81D59E65B59663D55C5E20DFEC592C",
          handler_max_unacked_commits: 0,
          handler_max_batch_size: 1000,
          offset_reset_policy: :latest,
          fetch_max_bytes: 1_000_000,
          fetch_interval_ms: 30000,
          handler_cooldown_ms: 0,
          isolation_level: :read_uncommitted
        ],
        [
          name: "A19F1C6483D6D9EB891B1E1306AA1AEE89742C6BB4D4B388FA2F4481E9E7",
          fetch_strategy: {:shared, :klife_default_fetcher},
          handler_max_unacked_commits: 0,
          handler_max_batch_size: :dynamic,
          offset_reset_policy: :latest,
          fetch_max_bytes: 1_000_000,
          max_queue_size: 10,
          fetch_interval_ms: 5000,
          handler_cooldown_ms: 0,
          isolation_level: :read_committed
        ],
        [
          name: "3DFF90B9A4D146917DB5A53CE1D80AE3D77F904E5DA09F6275BC247EF94E",
          handler_max_unacked_commits: 0,
          handler_max_batch_size: 200,
          offset_reset_policy: :earliest,
          fetch_max_bytes: 1_000_000,
          max_queue_size: 10,
          fetch_interval_ms: 30000,
          handler_cooldown_ms: 0,
          isolation_level: :read_committed
        ],
        [
          name: "18FAA84C74D8DD647CA5AF4E85ED384B81DA006994F59C51ADDA7C56BF3D",
          handler_max_unacked_commits: 0,
          handler_max_batch_size: :dynamic,
          offset_reset_policy: :latest,
          fetch_max_bytes: 1_000_000,
          max_queue_size: 20,
          fetch_interval_ms: 2500,
          handler_cooldown_ms: 0,
          isolation_level: :read_committed
        ],
        [
          name: "1D8B632DAF3B60F25FCA0B7048F91E26A27E5D870FB4764788071FE998BD",
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
          handler_max_unacked_commits: 0,
          handler_max_batch_size: 100,
          offset_reset_policy: :earliest,
          fetch_max_bytes: 1_000_000,
          fetch_interval_ms: 5000,
          handler_cooldown_ms: 0,
          isolation_level: :read_committed
        ],
        [
          name: "772ABE130905A7F5492A594C7A4CC8D2A899C9EDEA07E771E5EB17CE6665",
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
          handler_max_unacked_commits: 0,
          handler_max_batch_size: 200,
          offset_reset_policy: :latest,
          fetch_max_bytes: 1_000_000,
          fetch_interval_ms: 30000,
          handler_cooldown_ms: 0,
          isolation_level: :read_committed
        ],
        [
          name: "F9C4AECEE20E29546C58DF829B8023BAD97049A871DA17A4B9344FB2AB3D",
          fetch_strategy: {:shared, :klife_default_fetcher},
          handler_max_unacked_commits: 0,
          handler_max_batch_size: :dynamic,
          offset_reset_policy: :latest,
          fetch_max_bytes: 1_000_000,
          max_queue_size: 20,
          fetch_interval_ms: 5000,
          handler_cooldown_ms: 0,
          isolation_level: :read_committed
        ]
      ],
      group_name: "SimulatorGroup3",
      fetch_strategy: {:shared, :klife_default_fetcher}
    ],
    [
      cg_mod: Simulator.Engine.Consumer.NormalClient1,
      isolation_level: :read_committed,
      committers_count: 1,
      rebalance_timeout_ms: 20000,
      client: Simulator.NormalClient,
      topics: [
        [
          name: "5B9C2873DBCE5875B0A8E59AA4EF2CC29B951ED8BA4C57265BD31BB11D10",
          handler_max_unacked_commits: 0,
          handler_max_batch_size: :dynamic,
          offset_reset_policy: :latest,
          fetch_max_bytes: 1_000_000,
          max_queue_size: 20,
          fetch_interval_ms: 10000,
          handler_cooldown_ms: 0,
          isolation_level: :read_committed
        ],
        [
          name: "040BED68F9F276B0951092957BFA07A94C3307AC62DD90058097A2A04122",
          fetch_strategy:
            {:exclusive,
             [
               request_timeout_ms: 5000,
               client_id: nil,
               isolation_level: :read_committed,
               max_bytes: 500_000,
               min_bytes: 1,
               max_wait_ms: 1000
             ]},
          handler_max_unacked_commits: 0,
          handler_max_batch_size: :dynamic,
          offset_reset_policy: :latest,
          fetch_max_bytes: 1_000_000,
          fetch_interval_ms: 30000,
          handler_cooldown_ms: 0,
          isolation_level: :read_committed
        ],
        [
          name: "539A81A910AAF349E8EA597771CF3B622DA24EFC324A1C2DD0F105AF7405",
          handler_max_unacked_commits: 0,
          handler_max_batch_size: :dynamic,
          offset_reset_policy: :latest,
          fetch_max_bytes: 1_000_000,
          max_queue_size: 20,
          fetch_interval_ms: 5000,
          handler_cooldown_ms: 0,
          isolation_level: :read_committed
        ],
        [
          name: "B5E9D2FFCAAE7BBEE84E9279A7B9DE81D59E65B59663D55C5E20DFEC592C",
          handler_max_unacked_commits: 0,
          handler_max_batch_size: 200,
          offset_reset_policy: :latest,
          fetch_max_bytes: 1_000_000,
          max_queue_size: 10,
          fetch_interval_ms: 5000,
          handler_cooldown_ms: 0,
          isolation_level: :read_uncommitted
        ],
        [
          name: "A19F1C6483D6D9EB891B1E1306AA1AEE89742C6BB4D4B388FA2F4481E9E7",
          handler_max_unacked_commits: 0,
          handler_max_batch_size: :dynamic,
          offset_reset_policy: :latest,
          fetch_max_bytes: 1_000_000,
          fetch_interval_ms: 5000,
          handler_cooldown_ms: 0,
          isolation_level: :read_committed
        ],
        [
          name: "3DFF90B9A4D146917DB5A53CE1D80AE3D77F904E5DA09F6275BC247EF94E",
          fetch_strategy:
            {:exclusive,
             [
               request_timeout_ms: 10000,
               client_id: nil,
               isolation_level: :read_committed,
               max_bytes: 500_000,
               min_bytes: 1,
               max_wait_ms: 1000
             ]},
          handler_max_unacked_commits: 0,
          handler_max_batch_size: :dynamic,
          offset_reset_policy: :latest,
          fetch_max_bytes: 1_000_000,
          fetch_interval_ms: 5000,
          handler_cooldown_ms: 0,
          isolation_level: :read_committed
        ],
        [
          name: "18FAA84C74D8DD647CA5AF4E85ED384B81DA006994F59C51ADDA7C56BF3D",
          handler_max_unacked_commits: 0,
          handler_max_batch_size: 200,
          offset_reset_policy: :latest,
          fetch_max_bytes: 1_000_000,
          fetch_interval_ms: 5000,
          handler_cooldown_ms: 0,
          isolation_level: :read_committed
        ],
        [
          name: "1D8B632DAF3B60F25FCA0B7048F91E26A27E5D870FB4764788071FE998BD",
          handler_max_unacked_commits: 0,
          handler_max_batch_size: 200,
          offset_reset_policy: :latest,
          fetch_max_bytes: 1_000_000,
          max_queue_size: 50,
          fetch_interval_ms: 5000,
          handler_cooldown_ms: 0,
          isolation_level: :read_uncommitted
        ],
        [
          name: "772ABE130905A7F5492A594C7A4CC8D2A899C9EDEA07E771E5EB17CE6665",
          handler_max_unacked_commits: 0,
          handler_max_batch_size: 200,
          offset_reset_policy: :latest,
          fetch_max_bytes: 1_000_000,
          max_queue_size: 50,
          fetch_interval_ms: 5000,
          handler_cooldown_ms: 0,
          isolation_level: :read_committed
        ],
        [
          name: "F9C4AECEE20E29546C58DF829B8023BAD97049A871DA17A4B9344FB2AB3D",
          handler_max_unacked_commits: 0,
          handler_max_batch_size: 100,
          offset_reset_policy: :latest,
          fetch_max_bytes: 1_000_000,
          fetch_interval_ms: 5000,
          handler_cooldown_ms: 0,
          isolation_level: :read_uncommitted
        ]
      ],
      group_name: "SimulatorGroup4",
      fetch_strategy: {:shared, :klife_default_fetcher}
    ],
    [
      cg_mod: Simulator.Engine.Consumer.TLSClient1,
      isolation_level: :read_committed,
      committers_count: 1,
      rebalance_timeout_ms: 60000,
      client: Simulator.TLSClient,
      topics: [
        [
          name: "5B9C2873DBCE5875B0A8E59AA4EF2CC29B951ED8BA4C57265BD31BB11D10",
          handler_max_unacked_commits: 0,
          handler_max_batch_size: :dynamic,
          offset_reset_policy: :latest,
          fetch_max_bytes: 1_000_000,
          max_queue_size: 20,
          fetch_interval_ms: 30000,
          handler_cooldown_ms: 0,
          isolation_level: :read_committed
        ],
        [
          name: "040BED68F9F276B0951092957BFA07A94C3307AC62DD90058097A2A04122",
          fetch_strategy: {:shared, :klife_default_fetcher},
          handler_max_unacked_commits: 0,
          handler_max_batch_size: 100,
          offset_reset_policy: :latest,
          fetch_max_bytes: 1_000_000,
          fetch_interval_ms: 5000,
          handler_cooldown_ms: 0,
          isolation_level: :read_committed
        ],
        [
          name: "539A81A910AAF349E8EA597771CF3B622DA24EFC324A1C2DD0F105AF7405",
          handler_max_unacked_commits: 0,
          handler_max_batch_size: :dynamic,
          offset_reset_policy: :latest,
          fetch_max_bytes: 1_000_000,
          max_queue_size: 20,
          fetch_interval_ms: 5000,
          handler_cooldown_ms: 0,
          isolation_level: :read_committed
        ],
        [
          name: "B5E9D2FFCAAE7BBEE84E9279A7B9DE81D59E65B59663D55C5E20DFEC592C",
          handler_max_unacked_commits: 0,
          handler_max_batch_size: 100,
          offset_reset_policy: :latest,
          fetch_max_bytes: 1_000_000,
          fetch_interval_ms: 5000,
          handler_cooldown_ms: 0,
          isolation_level: :read_uncommitted
        ],
        [
          name: "A19F1C6483D6D9EB891B1E1306AA1AEE89742C6BB4D4B388FA2F4481E9E7",
          handler_max_unacked_commits: 0,
          handler_max_batch_size: :dynamic,
          offset_reset_policy: :latest,
          fetch_max_bytes: 1_000_000,
          fetch_interval_ms: 5000,
          handler_cooldown_ms: 0,
          isolation_level: :read_committed
        ],
        [
          name: "3DFF90B9A4D146917DB5A53CE1D80AE3D77F904E5DA09F6275BC247EF94E",
          handler_max_unacked_commits: 0,
          handler_max_batch_size: :dynamic,
          offset_reset_policy: :latest,
          fetch_max_bytes: 1_000_000,
          fetch_interval_ms: 2500,
          handler_cooldown_ms: 0,
          isolation_level: :read_committed
        ],
        [
          name: "18FAA84C74D8DD647CA5AF4E85ED384B81DA006994F59C51ADDA7C56BF3D",
          handler_max_unacked_commits: 0,
          handler_max_batch_size: 1000,
          offset_reset_policy: :latest,
          fetch_max_bytes: 1_000_000,
          fetch_interval_ms: 5000,
          handler_cooldown_ms: 0,
          isolation_level: :read_uncommitted
        ],
        [
          name: "1D8B632DAF3B60F25FCA0B7048F91E26A27E5D870FB4764788071FE998BD",
          handler_max_unacked_commits: 0,
          handler_max_batch_size: 100,
          offset_reset_policy: :latest,
          fetch_max_bytes: 1_000_000,
          fetch_interval_ms: 10000,
          handler_cooldown_ms: 0,
          isolation_level: :read_committed
        ],
        [
          name: "772ABE130905A7F5492A594C7A4CC8D2A899C9EDEA07E771E5EB17CE6665",
          handler_max_unacked_commits: 0,
          handler_max_batch_size: 100,
          offset_reset_policy: :latest,
          fetch_max_bytes: 1_000_000,
          max_queue_size: 10,
          fetch_interval_ms: 5000,
          handler_cooldown_ms: 0,
          isolation_level: :read_committed
        ],
        [
          name: "F9C4AECEE20E29546C58DF829B8023BAD97049A871DA17A4B9344FB2AB3D",
          handler_max_unacked_commits: 0,
          handler_max_batch_size: :dynamic,
          offset_reset_policy: :latest,
          fetch_max_bytes: 1_000_000,
          fetch_interval_ms: 1000,
          handler_cooldown_ms: 0,
          isolation_level: :read_committed
        ]
      ],
      group_name: "SimulatorGroup5",
      fetch_strategy: {:shared, :klife_default_fetcher}
    ]
  ],
  producer_max_rps: 80,
  producer_concurrency: 5,
  producer_loop_interval_ms: 1000,
  record_value_bytes: 10,
  record_key_bytes: 64,
  invariants_check_interval_ms: 5000,
  lag_warning_multiplier: nil
}
