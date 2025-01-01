defmodule Fog.LogStore do
  defp folder_for(key0, key1) do
    cfg = Application.fetch_env!(:fog, Fog.LogStore)
    data_path = Path.expand(cfg[:data_path])
    path = Path.join([data_path, key0, key1])
    File.mkdir_p!(path)
    path
  end

  defp file_for(key0, key1) do
    now = DateTime.utc_now()
    Path.join([folder_for(key0, key1), "#{now.year}-#{now.month}-#{now.day}.log"])
  end

  def store(key0, key1, line) do
    log_path = file_for(key0, key1)
    {:ok, file} = File.open(log_path, [:append])
    timestamp = DateTime.utc_now() |> DateTime.to_unix()
    IO.write(file, "#{timestamp}\t#{line}\n")
    File.close(file)
  end
end
