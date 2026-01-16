defmodule Simulator do
  @clients [Simulator.NormalClient, Simulator.TLSClient]
  def start_metrics() do
    # TODO: Enhance metrics!
    spawn(fn ->
      :ets.new(:support_metrics, [:set, :public, :named_table])

      Stream.interval(5_000)
      |> Enum.each(fn iteration ->
        Enum.each(@clients, fn c ->
          connection_metrics = connection_metrics(c)

          data =
            %{
              inflight_count: in_flight_count(c)
            }
            |> Map.merge(connection_metrics)
            |> IO.inspect(label: "Metrics for #{c}")

          true = :ets.insert(:support_metrics, {{c, iteration}, data})
        end)
      end)
    end)
  end

  def in_flight_count(client_name) do
    table = :"in_flight_messages.#{client_name}"
    :ets.info(table, :size)
  end

  def connection_metrics(client) do
    samples =
      for broker_id <- Klife.Connection.Controller.get_known_brokers(client),
          bidx <- 0..(Klife.Connection.Controller.get_connection_count(client) - 1) do
        conn = Klife.Connection.Broker.get_connection(client, broker_id, bidx)

        [{pid, _}] =
          Klife.ProcessRegistry.registry_lookup(
            {Klife.Connection.Broker, broker_id, client, bidx}
          )

        {:message_queue_len, mq_len} = Process.info(pid, :message_queue_len)

        mod = if conn.ssl, do: :ssl, else: :inet

        {:ok, stats} = mod.getstat(conn.socket, [:send_oct, :recv_oct, :recv_cnt, :send_cnt])

        %{
          message_queue_len: mq_len,
          send_oct: stats[:send_oct],
          recv_oct: stats[:recv_oct],
          recv_cnt: stats[:recv_cnt],
          send_cnt: stats[:send_cnt]
        }
      end

    mq_sum = Enum.sum_by(samples, fn s -> s.message_queue_len end)
    send_sum = Float.round(Enum.sum_by(samples, fn s -> s.send_oct end) / (1024 * 1024), 2)
    recv_sum = Float.round(Enum.sum_by(samples, fn s -> s.recv_oct end) / (1024 * 1024), 2)
    recv_count_sum = Enum.sum_by(samples, fn s -> s.recv_cnt end)
    send_count_sum = Enum.sum_by(samples, fn s -> s.send_cnt end)

    %{
      message_queue_len: mq_sum,
      socket_sent_mb: send_sum,
      socket_received_mb: recv_sum,
      socket_packets_received: recv_count_sum,
      socket_packets_sent: send_count_sum
    }
  end
end
