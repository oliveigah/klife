defmodule Klife.Producer.Murmur2 do
  import Bitwise

  @m 0x5BD1E995
  @r 24
  @seed 0x9747B28C
  @mask 0xFFFFFFFF

  def hash(data) when is_binary(data) do
    len = byte_size(data)
    h = bxor(@seed, len)
    h = process_blocks(data, h)

    # Convert to signed 32-bit integer to match Kafka's Utils.murmur2 return type
    if h >= 0x80000000, do: h - 0x100000000, else: h
  end

  defp process_blocks(<<k::little-32, rest::binary>>, h) do
    k = k * @m &&& @mask
    k = bxor(k, k >>> @r) * @m &&& @mask

    h = bxor(h * @m &&& @mask, k)
    process_blocks(rest, h)
  end

  defp process_blocks(<<b1, b2, b3>>, h) do
    h = bxor(bxor(bxor(h, b3 <<< 16), b2 <<< 8), b1) * @m &&& @mask
    mix(h)
  end

  defp process_blocks(<<b1, b2>>, h) do
    h = bxor(bxor(h, b2 <<< 8), b1) * @m &&& @mask
    mix(h)
  end

  defp process_blocks(<<b1>>, h) do
    h = bxor(h, b1) * @m &&& @mask
    mix(h)
  end

  defp process_blocks(<<>>, h), do: mix(h)

  defp mix(h) do
    h = bxor(h, h >>> 13) * @m &&& @mask
    bxor(h, h >>> 15)
  end
end
