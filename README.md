# Loader

## disclaimer

i started working on this project as a result of a suggestion from a friend that it would be a useful exploration to build a load tester and using it against naively constructed services to practice building/ fixing systems to make them more resilient against load.

this project is not now, and may never, be suitable for use by others, but i hope it will be!

## Summary

<!-- MDOC !-->
<!-- DESCRIPTION !-->

`Loader` is a load-generating library that allows you to define arbitrary distributions of arbitrary work via mathematical functions and small structs. 

<!-- DESCRIPTION !-->

These distributions, called `LoadProfile`s, can be paired up with a `WorkSpec` and executed to generate load, and gather statistics from a client's perspective.


## Example

Let's assume there is some service at `http://website.io/public/api`, and we want to generate some simple, uniform load against that service.

```elixir

alias Loader.{LoadProfile, WorkResponse, WorkSpec}

uniform_one_minute_profile =
  LoadProfile.new(%{
    target_running_time: 60,
    function: &LoadProfile.Curves.uniform(&1, 10) # y = 10
  })

service_call_spec = %WorkSpec{
  task: fn ->
    Finch.build(:get, "http://website.io/public/api", [])
    |> Finch.request(MyApp.Finch)
  end,
  is_success?: fn %WorkResponse{data: res} ->
    case res do
      {:ok, _any} -> true
      _any -> false
    end
  end
}

Loader.execute_profile(uniform_one_minute_profile, service_call_spec)
```

The above example will generate a uniform 10 requests/ second against our imaginary service. We could also write additional load profiles, and run them concurrently to generate constructive interference!

```elixir
linear_one_minute_profile =
  LoadProfile.new(%{
    target_running_time: 60,
    function: &LoadProfile.Curves.linear(&1, 1.5, 5) # y = 1.5x + 5
  })

sine_wave_one_minute_profile =
  LoadProfile.new(%{
    target_running_time: 60,
    function: fn x -> 5 * (:math.sin(x) + 1) end # y = 5 * (sin(x) + 1)
  })

Loader.execute_profiles([
  {uniform_one_minute_profile, service_call_spec},
  {linear_one_minute_profile, service_call_spec},
  {sine_wave_one_minute_profile, service_call_spec},
])
```

Visualized, this second example would produce load on the service as shown, where `x` is in seconds and `y` is requests/ second:

<img width="400 px" alt="constructive interference load graph" src="https://user-images.githubusercontent.com/47335328/249553919-631be393-0639-4855-9760-0b5db8092969.png">

## Telemetry

`Loader` emits the following telemetry events:

- `[:loader, :load_profile_execution, :start]` - emitted when `Loader.execute_profile/2` or `Loader.execute_profiles/1` is called.
- `[:loader, :load_profile_execution, :stop]` - emitted when a `LoadProfile` has been fully emitted, regardless of the number of successes or failures of individual tasks
- `[:loader, :task, :start]` - emitted when the `:task` callback from a `Loader.WorkSpec` is invoked
- `[:loader, :task, :stop]` - emitted when the `:task` callback from a `Loader.WorkSpec` is invoked
- `[:loader, :task, :exception]` - emitted if there is an uncaught exception while invoking the `:task` callback from a `Loader.WorkSpec`

See the documentation for the `Loader.Telemetry` module for more information.

## Installation

The package can be installed by adding `loader` to your list of dependencies in `mix.exs`:

```elixir
def deps do
  [
    {:loader, "~> 0.2.0"}
  ]
end
```

The docs can be found at <https://hexdocs.pm/loader>.

