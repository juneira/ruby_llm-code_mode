# frozen_string_literal: true

module RubyLLM
  class CodeMode
    parameter :code, description: "Complete Ruby script to execute in the sandbox"

    # Binds more host tools onto this specific instance, on top of the
    # class-level ones. Accepts the same forms as the class-level .tools:
    # classes, ready instances, several at once, arrays, and
    # "name" => tool pairs (hash or kwargs). Instances of the same class are
    # unaffected, and the additions show up in this instance's description,
    # so chats built after the call expose them to the model. Fails fast and
    # rolls everything back; once the first execution happened the sandbox is
    # already built and further additions raise.
    def add_tools(*args, **kwargs)
      ensure_extendable!

      Registry.register_tools(instance_tools, args, kwargs, reserved: self.class.tools)
    end

    # Connects MCP server(s) onto this specific instance, on top of the
    # class-level ones. Same forms and fail-fast semantics as .mcps
    # (instances, classes with their declared inputs, arrays); the servers'
    # tools bind into this instance only. Raises after the first execution.
    def add_mcps(*servers, **inputs)
      ensure_extendable!

      Registry.register_mcps(instance_tools, instance_mcps, servers, inputs, reserved: self.class.tools)
    end

    # The description this instance presents to the model: the class-level
    # build plus the tools and MCP servers added with #add_tools/#add_mcps.
    # RubyLLM reads it when the tool is registered with a chat, so call
    # chat.with_tools after the additions.
    def description
      self.class.build_description(extra_tools: instance_tools, extra_mcps: instance_mcps)
    end

    # Runs the model-generated Ruby script inside the sandbox and returns
    # the result as a hash for the model: `status` ("ok", "error",
    # "timeout", "fuel_exhausted", "memory_limit" or "sandbox_error"),
    # `value` on success, `error` otherwise, plus `stdout`/`stderr` when
    # the guest produced output. Sandbox failures (missing image, invalid
    # configuration) come back as a recoverable "sandbox_error" instead of
    # raising.
    def execute(code:)
      format_result(sandbox.eval(code))
    rescue SecurityBox::Error => e
      { status: "sandbox_error", error: { class: e.class.name, message: e.message } }
    end

    private

    def ensure_extendable!
      return unless instance_variable_defined?(:@sandbox)

      raise ArgumentError,
            "cannot add tools or MCP servers after the first execution; " \
            "create a new #{self.class.name} instance instead"
    end

    def instance_tools
      @instance_tools ||= {}
    end

    def instance_mcps
      @instance_mcps ||= []
    end

    # Instances without additions share the class configuration; instances
    # with additions build their own, merging the class rpcs with the
    # instance ones (names cannot collide — the registrations validate that).
    def configuration
      return self.class.configuration if instance_tools.empty? && instance_mcps.empty?

      @configuration ||= SecurityBox::Configuration.build(
        timeout_ms: DEFAULT_TIMEOUT_MS,
        fuel_ms: DEFAULT_FUEL_MS,
        mounts: self.class.mounts.map(&:payload),
        rpcs: self.class.configuration.rpcs.merge(Registry.rpc_handlers(instance_tools))
      )
    end

    def sandbox
      @sandbox ||= SecurityBox::Sandbox.new(configuration)
    end

    def format_result(result)
      payload = { status: result.status.to_s }
      case result.status
      when :ok
        payload[:value] = result.value
      when :error
        payload[:error] = result.error || { "class" => "Unknown", "message" => "guest code failed" }
      when :timeout
        payload[:error] = "execution timed out before finishing"
      when :fuel_exhausted
        payload[:error] = "execution exceeded its CPU budget before finishing"
      when :memory_limit
        payload[:error] = "execution exceeded the sandbox memory limit"
      when :sandbox_error
        payload[:error] = "the sandbox failed to run the code"
      end
      payload[:stdout] = result.stdout if result.stdout && !result.stdout.empty?
      payload[:stderr] = result.stderr if result.stderr && !result.stderr.empty?
      payload
    end
  end
end
