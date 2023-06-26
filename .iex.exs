service_request_spec = %Loader.WorkSpec{
  task: fn req_count ->
    Loader.send_requests(:get, "http://localhost:3000/services", count: req_count)
  end,
  is_success?: fn %Loader.WorkResponse{response: res} ->
    case res do
      {:ok, _any} -> true
      _any -> false
    end
  end
}

profiles = %{
  default: %Loader.LoadProfile{},
  three_k_uniform: %Loader.LoadProfile{total_task_count: 3_000}
}
