%Simulator.EngineConfig{
  clients: [Simulator.NormalClient, Simulator.TLSClient],
  topics: [
    %{partitions: 20, topic: "F4F330E08B0936AF9D7B700EC3317BAE7BBD90FDB90615481BA11E3E6320"},
    %{partitions: 20, topic: "F398869CCCC89B20E76D09C345761C34B790719352775BEAA1C6A1858F9C"},
    %{partitions: 20, topic: "992D9C5BA192F7F7451A730CE6D1D5CC4E6C3A92F822DD55C9DD6E4060EA"},
    %{partitions: 20, topic: "D784C4B71B080E1BCDB32DDCFFB5C8643B4F7C1708C39AD392BF9D8EB843"},
    %{partitions: 20, topic: "B7CCB869A6BB7D5BA04A8DF0EE0268E265096981A438621F5732466A51EC"},
    %{partitions: 20, topic: "00F1F291FF395F314289F6512B05192BF593930BBBA8BFACB341F855575A"},
    %{partitions: 20, topic: "CCBAC3CD5C36BF765A54DBFE444DCCCFA79A6BF8747C78CCFDA54093BA53"},
    %{partitions: 20, topic: "D69F976FCD3182DBF4BE17B7678EF5476E81008FBF5781BA3168FD08D78E"},
    %{partitions: 20, topic: "C0FF90CEB944361294F95303B3FDE9BA7BC8E9AFB5DC33DC873E59B50C3C"},
    %{partitions: 20, topic: "79EFEF9F956F6316090F33CBB09CC33DE3F24B8C44F081A8995EB16BBB5C"}
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
          name: "F4F330E08B0936AF9D7B700EC3317BAE7BBD90FDB90615481BA11E3E6320",
          isolation_level: :read_committed,
          fetch_interval_ms: 2500,
          fetch_max_bytes: 1_000_000,
          handler_cooldown_ms: 0,
          handler_max_batch_size: 1000,
          handler_max_unacked_commits: 0,
          max_queue_size: 50,
          offset_reset_policy: :latest
        ],
        [
          name: "F398869CCCC89B20E76D09C345761C34B790719352775BEAA1C6A1858F9C",
          isolation_level: :read_committed,
          fetch_interval_ms: 5000,
          fetch_max_bytes: 1_000_000,
          handler_cooldown_ms: 0,
          handler_max_batch_size: 1000,
          handler_max_unacked_commits: 0,
          max_queue_size: 10,
          offset_reset_policy: :latest
        ],
        [
          name: "992D9C5BA192F7F7451A730CE6D1D5CC4E6C3A92F822DD55C9DD6E4060EA",
          isolation_level: :read_committed,
          fetch_interval_ms: 5000,
          fetch_max_bytes: 1_000_000,
          handler_cooldown_ms: 0,
          handler_max_batch_size: 200,
          handler_max_unacked_commits: 0,
          offset_reset_policy: :latest
        ],
        [
          name: "D784C4B71B080E1BCDB32DDCFFB5C8643B4F7C1708C39AD392BF9D8EB843",
          isolation_level: :read_committed,
          fetch_interval_ms: 10000,
          fetch_max_bytes: 1_000_000,
          handler_cooldown_ms: 0,
          handler_max_batch_size: :dynamic,
          handler_max_unacked_commits: 0,
          offset_reset_policy: :latest
        ],
        [
          name: "B7CCB869A6BB7D5BA04A8DF0EE0268E265096981A438621F5732466A51EC",
          isolation_level: :read_committed,
          fetch_strategy:
            {:exclusive,
             [
               request_timeout_ms: 5000,
               client_id: nil,
               isolation_level: :read_committed,
               max_bytes: 250_000,
               min_bytes: 1,
               max_wait_ms: 0
             ]},
          fetch_interval_ms: 10000,
          fetch_max_bytes: 1_000_000,
          handler_cooldown_ms: 0,
          handler_max_batch_size: :dynamic,
          handler_max_unacked_commits: 0,
          offset_reset_policy: :latest
        ],
        [
          name: "00F1F291FF395F314289F6512B05192BF593930BBBA8BFACB341F855575A",
          isolation_level: :read_committed,
          fetch_interval_ms: 2500,
          fetch_max_bytes: 1_000_000,
          handler_cooldown_ms: 0,
          handler_max_batch_size: 200,
          handler_max_unacked_commits: 0,
          offset_reset_policy: :latest
        ],
        [
          name: "CCBAC3CD5C36BF765A54DBFE444DCCCFA79A6BF8747C78CCFDA54093BA53",
          isolation_level: :read_committed,
          fetch_interval_ms: 1000,
          fetch_max_bytes: 1_000_000,
          handler_cooldown_ms: 0,
          handler_max_batch_size: 200,
          handler_max_unacked_commits: 0,
          offset_reset_policy: :latest
        ],
        [
          name: "D69F976FCD3182DBF4BE17B7678EF5476E81008FBF5781BA3168FD08D78E",
          isolation_level: :read_committed,
          fetch_strategy:
            {:exclusive,
             [
               request_timeout_ms: 10000,
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
          name: "C0FF90CEB944361294F95303B3FDE9BA7BC8E9AFB5DC33DC873E59B50C3C",
          isolation_level: :read_committed,
          fetch_strategy:
            {:exclusive,
             [
               request_timeout_ms: 5000,
               client_id: nil,
               isolation_level: :read_committed,
               max_bytes: 250_000,
               min_bytes: 1,
               max_wait_ms: 0
             ]},
          fetch_interval_ms: 2500,
          fetch_max_bytes: 1_000_000,
          handler_cooldown_ms: 0,
          handler_max_batch_size: :dynamic,
          handler_max_unacked_commits: 0,
          offset_reset_policy: :latest
        ],
        [
          name: "79EFEF9F956F6316090F33CBB09CC33DE3F24B8C44F081A8995EB16BBB5C",
          isolation_level: :read_committed,
          fetch_interval_ms: 30000,
          fetch_max_bytes: 1_000_000,
          handler_cooldown_ms: 0,
          handler_max_batch_size: 1000,
          handler_max_unacked_commits: 0,
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
      rebalance_timeout_ms: 10000,
      client: Simulator.TLSClient,
      topics: [
        [
          name: "F4F330E08B0936AF9D7B700EC3317BAE7BBD90FDB90615481BA11E3E6320",
          isolation_level: :read_uncommitted,
          fetch_interval_ms: 10000,
          fetch_max_bytes: 1_000_000,
          handler_cooldown_ms: 0,
          handler_max_batch_size: 100,
          handler_max_unacked_commits: 0,
          offset_reset_policy: :latest
        ],
        [
          name: "F398869CCCC89B20E76D09C345761C34B790719352775BEAA1C6A1858F9C",
          isolation_level: :read_committed,
          fetch_interval_ms: 10000,
          fetch_max_bytes: 1_000_000,
          handler_cooldown_ms: 0,
          handler_max_batch_size: 1000,
          handler_max_unacked_commits: 0,
          max_queue_size: 10,
          offset_reset_policy: :latest
        ],
        [
          name: "992D9C5BA192F7F7451A730CE6D1D5CC4E6C3A92F822DD55C9DD6E4060EA",
          isolation_level: :read_committed,
          fetch_interval_ms: 2500,
          fetch_max_bytes: 1_000_000,
          handler_cooldown_ms: 0,
          handler_max_batch_size: 200,
          handler_max_unacked_commits: 0,
          offset_reset_policy: :latest
        ],
        [
          name: "D784C4B71B080E1BCDB32DDCFFB5C8643B4F7C1708C39AD392BF9D8EB843",
          isolation_level: :read_committed,
          fetch_interval_ms: 5000,
          fetch_max_bytes: 1_000_000,
          handler_cooldown_ms: 0,
          handler_max_batch_size: 200,
          handler_max_unacked_commits: 0,
          max_queue_size: 10,
          offset_reset_policy: :latest
        ],
        [
          name: "B7CCB869A6BB7D5BA04A8DF0EE0268E265096981A438621F5732466A51EC",
          isolation_level: :read_committed,
          fetch_interval_ms: 1000,
          fetch_max_bytes: 1_000_000,
          handler_cooldown_ms: 0,
          handler_max_batch_size: :dynamic,
          handler_max_unacked_commits: 0,
          max_queue_size: 50,
          offset_reset_policy: :latest
        ],
        [
          name: "00F1F291FF395F314289F6512B05192BF593930BBBA8BFACB341F855575A",
          isolation_level: :read_committed,
          fetch_interval_ms: 1000,
          fetch_max_bytes: 1_000_000,
          handler_cooldown_ms: 0,
          handler_max_batch_size: 1000,
          handler_max_unacked_commits: 0,
          max_queue_size: 10,
          offset_reset_policy: :latest
        ],
        [
          name: "CCBAC3CD5C36BF765A54DBFE444DCCCFA79A6BF8747C78CCFDA54093BA53",
          isolation_level: :read_committed,
          fetch_interval_ms: 30000,
          fetch_max_bytes: 1_000_000,
          handler_cooldown_ms: 0,
          handler_max_batch_size: 1000,
          handler_max_unacked_commits: 0,
          offset_reset_policy: :latest
        ],
        [
          name: "D69F976FCD3182DBF4BE17B7678EF5476E81008FBF5781BA3168FD08D78E",
          isolation_level: :read_uncommitted,
          fetch_strategy:
            {:exclusive,
             [
               request_timeout_ms: 5000,
               client_id: nil,
               isolation_level: :read_committed,
               max_bytes: 250_000,
               min_bytes: 1,
               max_wait_ms: 0
             ]},
          fetch_interval_ms: 5000,
          fetch_max_bytes: 1_000_000,
          handler_cooldown_ms: 0,
          handler_max_batch_size: 1000,
          handler_max_unacked_commits: 0,
          max_queue_size: 20,
          offset_reset_policy: :latest
        ],
        [
          name: "C0FF90CEB944361294F95303B3FDE9BA7BC8E9AFB5DC33DC873E59B50C3C",
          isolation_level: :read_committed,
          fetch_interval_ms: 5000,
          fetch_max_bytes: 1_000_000,
          handler_cooldown_ms: 0,
          handler_max_batch_size: :dynamic,
          handler_max_unacked_commits: 0,
          offset_reset_policy: :latest
        ],
        [
          name: "79EFEF9F956F6316090F33CBB09CC33DE3F24B8C44F081A8995EB16BBB5C",
          isolation_level: :read_committed,
          fetch_interval_ms: 5000,
          fetch_max_bytes: 1_000_000,
          handler_cooldown_ms: 0,
          handler_max_batch_size: :dynamic,
          handler_max_unacked_commits: 0,
          max_queue_size: 20,
          offset_reset_policy: :latest
        ]
      ],
      group_name: "SimulatorGroup2"
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
          name: "F4F330E08B0936AF9D7B700EC3317BAE7BBD90FDB90615481BA11E3E6320",
          isolation_level: :read_committed,
          fetch_interval_ms: 5000,
          fetch_max_bytes: 1_000_000,
          handler_cooldown_ms: 0,
          handler_max_batch_size: :dynamic,
          handler_max_unacked_commits: 0,
          offset_reset_policy: :latest
        ],
        [
          name: "F398869CCCC89B20E76D09C345761C34B790719352775BEAA1C6A1858F9C",
          isolation_level: :read_committed,
          fetch_strategy:
            {:exclusive,
             [
               request_timeout_ms: 5000,
               client_id: nil,
               isolation_level: :read_committed,
               max_bytes: 100_000,
               min_bytes: 1,
               max_wait_ms: 1000
             ]},
          fetch_interval_ms: 1000,
          fetch_max_bytes: 1_000_000,
          handler_cooldown_ms: 0,
          handler_max_batch_size: 200,
          handler_max_unacked_commits: 0,
          max_queue_size: 10,
          offset_reset_policy: :latest
        ],
        [
          name: "992D9C5BA192F7F7451A730CE6D1D5CC4E6C3A92F822DD55C9DD6E4060EA",
          isolation_level: :read_uncommitted,
          fetch_interval_ms: 30000,
          fetch_max_bytes: 1_000_000,
          handler_cooldown_ms: 0,
          handler_max_batch_size: 200,
          handler_max_unacked_commits: 0,
          offset_reset_policy: :latest
        ],
        [
          name: "D784C4B71B080E1BCDB32DDCFFB5C8643B4F7C1708C39AD392BF9D8EB843",
          isolation_level: :read_committed,
          fetch_interval_ms: 5000,
          fetch_max_bytes: 1_000_000,
          handler_cooldown_ms: 0,
          handler_max_batch_size: 200,
          handler_max_unacked_commits: 0,
          offset_reset_policy: :latest
        ],
        [
          name: "B7CCB869A6BB7D5BA04A8DF0EE0268E265096981A438621F5732466A51EC",
          isolation_level: :read_uncommitted,
          fetch_interval_ms: 2500,
          fetch_max_bytes: 1_000_000,
          handler_cooldown_ms: 0,
          handler_max_batch_size: :dynamic,
          handler_max_unacked_commits: 0,
          offset_reset_policy: :latest
        ],
        [
          name: "00F1F291FF395F314289F6512B05192BF593930BBBA8BFACB341F855575A",
          isolation_level: :read_committed,
          fetch_interval_ms: 5000,
          fetch_max_bytes: 1_000_000,
          handler_cooldown_ms: 0,
          handler_max_batch_size: 100,
          handler_max_unacked_commits: 0,
          offset_reset_policy: :latest
        ],
        [
          name: "CCBAC3CD5C36BF765A54DBFE444DCCCFA79A6BF8747C78CCFDA54093BA53",
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
          name: "D69F976FCD3182DBF4BE17B7678EF5476E81008FBF5781BA3168FD08D78E",
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
          name: "C0FF90CEB944361294F95303B3FDE9BA7BC8E9AFB5DC33DC873E59B50C3C",
          isolation_level: :read_committed,
          fetch_interval_ms: 5000,
          fetch_max_bytes: 1_000_000,
          handler_cooldown_ms: 0,
          handler_max_batch_size: :dynamic,
          handler_max_unacked_commits: 0,
          max_queue_size: 20,
          offset_reset_policy: :latest
        ],
        [
          name: "79EFEF9F956F6316090F33CBB09CC33DE3F24B8C44F081A8995EB16BBB5C",
          isolation_level: :read_uncommitted,
          fetch_interval_ms: 5000,
          fetch_max_bytes: 1_000_000,
          handler_cooldown_ms: 0,
          handler_max_batch_size: 100,
          handler_max_unacked_commits: 0,
          offset_reset_policy: :latest
        ]
      ],
      group_name: "SimulatorGroup3"
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
           max_bytes: 1_000_000,
           min_bytes: 1,
           max_wait_ms: 5000
         ]},
      rebalance_timeout_ms: 30000,
      client: Simulator.NormalClient,
      topics: [
        [
          name: "F4F330E08B0936AF9D7B700EC3317BAE7BBD90FDB90615481BA11E3E6320",
          isolation_level: :read_committed,
          fetch_interval_ms: 5000,
          fetch_max_bytes: 1_000_000,
          handler_cooldown_ms: 0,
          handler_max_batch_size: 1000,
          handler_max_unacked_commits: 0,
          offset_reset_policy: :latest
        ],
        [
          name: "F398869CCCC89B20E76D09C345761C34B790719352775BEAA1C6A1858F9C",
          isolation_level: :read_committed,
          fetch_interval_ms: 5000,
          fetch_max_bytes: 1_000_000,
          handler_cooldown_ms: 0,
          handler_max_batch_size: 200,
          handler_max_unacked_commits: 0,
          offset_reset_policy: :latest
        ],
        [
          name: "992D9C5BA192F7F7451A730CE6D1D5CC4E6C3A92F822DD55C9DD6E4060EA",
          isolation_level: :read_committed,
          fetch_interval_ms: 30000,
          fetch_max_bytes: 1_000_000,
          handler_cooldown_ms: 0,
          handler_max_batch_size: 1000,
          handler_max_unacked_commits: 0,
          offset_reset_policy: :latest
        ],
        [
          name: "D784C4B71B080E1BCDB32DDCFFB5C8643B4F7C1708C39AD392BF9D8EB843",
          isolation_level: :read_committed,
          fetch_interval_ms: 5000,
          fetch_max_bytes: 1_000_000,
          handler_cooldown_ms: 0,
          handler_max_batch_size: 100,
          handler_max_unacked_commits: 0,
          offset_reset_policy: :latest
        ],
        [
          name: "B7CCB869A6BB7D5BA04A8DF0EE0268E265096981A438621F5732466A51EC",
          isolation_level: :read_uncommitted,
          fetch_interval_ms: 1000,
          fetch_max_bytes: 1_000_000,
          handler_cooldown_ms: 0,
          handler_max_batch_size: :dynamic,
          handler_max_unacked_commits: 0,
          offset_reset_policy: :earliest
        ],
        [
          name: "00F1F291FF395F314289F6512B05192BF593930BBBA8BFACB341F855575A",
          isolation_level: :read_uncommitted,
          fetch_interval_ms: 5000,
          fetch_max_bytes: 1_000_000,
          handler_cooldown_ms: 0,
          handler_max_batch_size: 100,
          handler_max_unacked_commits: 0,
          max_queue_size: 50,
          offset_reset_policy: :latest
        ],
        [
          name: "CCBAC3CD5C36BF765A54DBFE444DCCCFA79A6BF8747C78CCFDA54093BA53",
          isolation_level: :read_committed,
          fetch_strategy:
            {:exclusive,
             [
               request_timeout_ms: 5000,
               client_id: nil,
               isolation_level: :read_committed,
               max_bytes: 5_000_000,
               min_bytes: 1,
               max_wait_ms: 0
             ]},
          fetch_interval_ms: 1000,
          fetch_max_bytes: 1_000_000,
          handler_cooldown_ms: 0,
          handler_max_batch_size: :dynamic,
          handler_max_unacked_commits: 0,
          offset_reset_policy: :latest
        ],
        [
          name: "D69F976FCD3182DBF4BE17B7678EF5476E81008FBF5781BA3168FD08D78E",
          isolation_level: :read_committed,
          fetch_interval_ms: 10000,
          fetch_max_bytes: 1_000_000,
          handler_cooldown_ms: 0,
          handler_max_batch_size: 100,
          handler_max_unacked_commits: 0,
          offset_reset_policy: :latest
        ],
        [
          name: "C0FF90CEB944361294F95303B3FDE9BA7BC8E9AFB5DC33DC873E59B50C3C",
          isolation_level: :read_committed,
          fetch_interval_ms: 5000,
          fetch_max_bytes: 1_000_000,
          handler_cooldown_ms: 0,
          handler_max_batch_size: 1000,
          handler_max_unacked_commits: 0,
          offset_reset_policy: :latest
        ],
        [
          name: "79EFEF9F956F6316090F33CBB09CC33DE3F24B8C44F081A8995EB16BBB5C",
          isolation_level: :read_committed,
          fetch_interval_ms: 5000,
          fetch_max_bytes: 1_000_000,
          handler_cooldown_ms: 0,
          handler_max_batch_size: 1000,
          handler_max_unacked_commits: 0,
          max_queue_size: 10,
          offset_reset_policy: :latest
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
           max_wait_ms: 0
         ]},
      rebalance_timeout_ms: 20000,
      client: Simulator.TLSClient,
      topics: [
        [
          name: "F4F330E08B0936AF9D7B700EC3317BAE7BBD90FDB90615481BA11E3E6320",
          isolation_level: :read_committed,
          fetch_interval_ms: 2500,
          fetch_max_bytes: 1_000_000,
          handler_cooldown_ms: 0,
          handler_max_batch_size: 200,
          handler_max_unacked_commits: 0,
          offset_reset_policy: :latest
        ],
        [
          name: "F398869CCCC89B20E76D09C345761C34B790719352775BEAA1C6A1858F9C",
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
          name: "992D9C5BA192F7F7451A730CE6D1D5CC4E6C3A92F822DD55C9DD6E4060EA",
          isolation_level: :read_committed,
          fetch_interval_ms: 30000,
          fetch_max_bytes: 1_000_000,
          handler_cooldown_ms: 0,
          handler_max_batch_size: 200,
          handler_max_unacked_commits: 0,
          max_queue_size: 20,
          offset_reset_policy: :latest
        ],
        [
          name: "D784C4B71B080E1BCDB32DDCFFB5C8643B4F7C1708C39AD392BF9D8EB843",
          isolation_level: :read_committed,
          fetch_interval_ms: 5000,
          fetch_max_bytes: 1_000_000,
          handler_cooldown_ms: 0,
          handler_max_batch_size: 1000,
          handler_max_unacked_commits: 0,
          max_queue_size: 20,
          offset_reset_policy: :latest
        ],
        [
          name: "B7CCB869A6BB7D5BA04A8DF0EE0268E265096981A438621F5732466A51EC",
          isolation_level: :read_committed,
          fetch_interval_ms: 5000,
          fetch_max_bytes: 1_000_000,
          handler_cooldown_ms: 0,
          handler_max_batch_size: :dynamic,
          handler_max_unacked_commits: 0,
          max_queue_size: 50,
          offset_reset_policy: :earliest
        ],
        [
          name: "00F1F291FF395F314289F6512B05192BF593930BBBA8BFACB341F855575A",
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
          name: "CCBAC3CD5C36BF765A54DBFE444DCCCFA79A6BF8747C78CCFDA54093BA53",
          isolation_level: :read_committed,
          fetch_interval_ms: 1000,
          fetch_max_bytes: 1_000_000,
          handler_cooldown_ms: 0,
          handler_max_batch_size: :dynamic,
          handler_max_unacked_commits: 0,
          offset_reset_policy: :latest
        ],
        [
          name: "D69F976FCD3182DBF4BE17B7678EF5476E81008FBF5781BA3168FD08D78E",
          isolation_level: :read_uncommitted,
          fetch_interval_ms: 30000,
          fetch_max_bytes: 1_000_000,
          handler_cooldown_ms: 0,
          handler_max_batch_size: 1000,
          handler_max_unacked_commits: 0,
          offset_reset_policy: :latest
        ],
        [
          name: "C0FF90CEB944361294F95303B3FDE9BA7BC8E9AFB5DC33DC873E59B50C3C",
          isolation_level: :read_committed,
          fetch_interval_ms: 5000,
          fetch_max_bytes: 1_000_000,
          handler_cooldown_ms: 0,
          handler_max_batch_size: 1000,
          handler_max_unacked_commits: 0,
          offset_reset_policy: :latest
        ],
        [
          name: "79EFEF9F956F6316090F33CBB09CC33DE3F24B8C44F081A8995EB16BBB5C",
          isolation_level: :read_committed,
          fetch_strategy:
            {:exclusive,
             [
               request_timeout_ms: 10000,
               client_id: nil,
               isolation_level: :read_committed,
               max_bytes: 500_000,
               min_bytes: 1,
               max_wait_ms: 0
             ]},
          fetch_interval_ms: 5000,
          fetch_max_bytes: 1_000_000,
          handler_cooldown_ms: 0,
          handler_max_batch_size: 100,
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
