defmodule Simulator.OAuthClient do
  use Klife.Client, otp_app: :simulator

  # Called on every new connection. Brokers accept unsecured JWTs ("alg": "none") and
  # end each session when its token expires, so connections are replaced once per
  # token lifetime: the current run's, or 60s before the first run starts
  def token do
    lifetime_s =
      case :persistent_term.get(:engine_config, nil) do
        %Simulator.EngineConfig{oauth_token_lifetime_s: s} when is_integer(s) -> s
        _ -> 60
      end

    exp = System.os_time(:second) + lifetime_s
    header = Base.url_encode64(~s({"alg":"none"}), padding: false)
    claims = Base.url_encode64(~s({"sub":"klifeusr","exp":#{exp}}), padding: false)
    "#{header}.#{claims}."
  end
end
