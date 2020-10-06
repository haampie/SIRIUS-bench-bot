module SiriusBenchBot

import GitHub, HTTP, YAML, Markdown, JSON
import OrderedCollections: OrderedDict
import Sockets: IPv4
import Base: RefValue

# If a comment matches this regex, it starts a bench
const trigger = r".*@siriusbot run.*"ms

# We push a commit to this repo to trigger pipelines.
const benchmark_repo = "git@gitlab.com:cscs-ci/electronic-structure/benchmarking.git"

# Just keep the auth bit as a global const value, but defer logging in to starting the
# server, so keep it around as a Union for now.
const auth = RefValue{Union{Nothing,GitHub.Authorization}}(nothing)

"""
User-provided config options.
"""
struct ConfigOptions
    reference_spec::Union{Nothing,String}
    reference_args::Union{Nothing,Vector{String}}
    spec::Union{Nothing,String}
    args::Union{Nothing,Vector{String}}
end

ConfigOptions() = ConfigOptions(nothing, nothing, nothing, nothing)

function dict_to_settings(dict)
    # top level spec / args
    default_spec = get(dict, "spec", nothing)
    default_args = get(dict, "args", nothing)

    # reference level settings
    if (reference = get(dict, "reference", nothing)) !== nothing
        reference_spec = get(reference, "spec", nothing)
        reference_args = get(reference, "args", nothing)
    else
        reference_spec = nothing
        reference_args = nothing
    end

    if reference_spec === nothing
        reference_spec = default_spec
    end

    if reference_args === nothing
        reference_args = default_args
    end

    # current level settings
    if (current = get(dict, "current", nothing)) !== nothing
        current_spec = get(current, "spec", nothing)
        current_args = get(current, "args", nothing)
    else
        current_spec = nothing
        current_args = nothing
    end

    if current_spec === nothing
        current_spec = default_spec
    end

    if current_args === nothing
        current_args = default_args
    end

    return ConfigOptions(
        reference_spec,
        reference_args,
        current_spec,
        current_args
    )
end

"""
    options_from_comment("some comment") -> ConfigOptions

Parse a comment as markdown, find the first top-level code block,
parse it as yaml for configuring the build.
"""
function options_from_comment(comment::AbstractString)
    try
        parsed_markdown = Markdown.parse(comment)

        # Look for a top-level code block
        code_block_idx = findfirst(x -> typeof(x) == Markdown.Code, parsed_markdown.content)
        code_block_idx === nothing && return ConfigOptions()
        
        # If found, try to parse it as yaml and extract some config options
        code_block::Markdown.Code = parsed_markdown.content[code_block_idx]

        return dict_to_settings(YAML.load(code_block.code))
    catch e
        @warn e
        return ConfigOptions()
    end
end

function handle_comment(event, phrase::RegexMatch)
    # Get user-provided options
    config = options_from_comment(phrase.match)

    # Get the target data
    if event.kind == "pull_request"
        current_repo = event.payload["pull_request"]["head"]["repo"]["full_name"]
        current_sha = event.payload["pull_request"]["head"]["sha"]
        reference_repo = event.payload["pull_request"]["base"]["repo"]["full_name"]
        reference_sha = event.payload["pull_request"]["base"]["sha"]
        prnumber = event.payload["pull_request"]["number"]
    elseif event.kind == "issue_comment"
        pr = GitHub.pull_request(event.repository, event.payload["issue"]["number"], auth = auth[])
        current_repo = pr.head.repo.full_name
        current_sha = pr.head.sha
        reference_repo = pr.base.repo.full_name
        reference_sha = pr.base.sha
        prnumber = pr.number
    else
        return HTTP.Response(200)
    end

    data_buffer = IOBuffer()
    benchmark_setup = JSON.print(data_buffer, OrderedDict(
        "type" => "compare",
        "reference" => OrderedDict(
            "spec" => something(config.reference_spec, "sirius@develop"),
            "args" => something(config.reference_args, String[]),
            "repo" => reference_repo,
            "sha" => reference_sha
        ),
        "current" => OrderedDict(
            "spec" => something(config.spec, "sirius@develop"),
            "args" => something(config.args, String[]),
            "repo" => current_repo,
            "sha" => current_sha
        ),
        "report_to" => OrderedDict(
            "repository" => event.repository.full_name,
            "issue" => prnumber,
            "type" => "pr"
        )
    ), 4)

    bench_setup = String(take!(data_buffer))

    # Create the benchmark
    cd(mktempdir()) do
        run(`git clone $benchmark_repo benchmarking`)

        cd("benchmarking") do
            open("benchmark.json", "w") do io
                print(io, bench_setup)
            end

            run(`git add -A`)
            run(`git commit --allow-empty -m "Benchmark $current_sha vs $reference_sha"`)
            run(`git push`)
        end
    end

    comment_params = Dict{String, Any}("body" =>
        """
        Benchmark started with the following settings:

        ```json
        $bench_setup
        ```
        """
    )

    GitHub.create_comment(
        event.repository,
        prnumber,
        :pr;
        auth = auth[],
        params = comment_params
    )

    return HTTP.Response(200)
end

function run(address = IPv4(0,0,0,0), port = 8080)
    auth[] = GitHub.authenticate(ENV["GITHUB_AUTH"])
    listener = GitHub.CommentListener(handle_comment, trigger; auth = auth[], secret = ENV["MY_SECRET"])
    GitHub.run(listener, address, port)
end

end # module
