# frozen_string_literal: true

require 'typhoeus'

module Faraday
  class Adapter
    # This class provides the main implementation for your adapter.
    # There are some key responsibilities that your adapter should satisfy:
    # * Initialize and store internally the client you chose (e.g. Net::HTTP)
    # * Process requests and save the response (see `#call`)
    class Typhoeus < Faraday::Adapter
      self.supports_parallel = true

      # The initialize method is lazy-called ONCE when the connection stack is built.
      # See https://github.com/lostisland/faraday/blob/master/lib/faraday/rack_builder.rb
      #
      # @param app [#call] the "rack app" wrapped in middleware. See https://github.com/lostisland/faraday/blob/master/lib/faraday/rack_builder.rb#L157
      # @param opts [Hash] the options hash with all the options necessary for the adapter to correctly configure itself.
      #   These are automatically stored into `@connection_options` when you call `super`.
      def initialize(app = nil, opts = {})
        super(app, opts)
      end

      # Setup Hydra with provided options.
      #
      # @example Setup Hydra.
      #   Faraday::Adapter::Typhoeus.setup_parallel_manager
      #   #=> #<Typhoeus::Hydra ... >
      #
      # @param (see Typhoeus::Hydra#initialize)
      # @option (see Typhoeus::Hydra#initialize)
      #
      # @return [ Typhoeus::Hydra ] The hydra.
      def self.setup_parallel_manager(options = {})
        ::Typhoeus::Hydra.new(options)
      end

      # This is the main method in your adapter. Since an adapter is a middleware, this method will be called FOR EVERY REQUEST.
      # The main task of this method is to perform a call using the internal client and save the response.
      # Since this method is not called directly f`rom the outside, you'll need to use `env` in order to:
      # * Get the request parameters (see `Faraday::Env` and `Faraday::RequestOptions` for the full list). This includes processing:
      #   * The request method, url, headers, parameters and body
      #   * The SSL configuration (env[:ssl])
      #   * The request configuration (env[:request]), i.e. things like: timeout, proxy, etc...
      # * Set the response attributes. This can be done easily by calling `save_response`. These include:
      #   * Response headers and body
      #   * Response status and reason_phrase
      #
      # @param env [Faraday::Env] the environment of the request being processed
      def call(env)
        super
        perform_request env
        @app.call env

        # NOTE: An adapter `call` MUST return the `env.response`. If `save_response` is the last line in your `call`
        # method implementation, it will automatically return the response for you.
        # Otherwise, you'll need to manually do so. You can do this with any (not both) of the following lines:
        # * @app.call(env)
        # * env.response
      # Finally, it's good practice to rescue client-specific exceptions (e.g. Timeout, ConnectionFailed, etc...)
      # and re-raise them as Faraday Errors. Check `Faraday::Error` for a list of all errors.
      # rescue MyAdapterTimeout => e
      #   # Most errors allow you to provide the original exception and optionally (if available) the response, to
      #   # make them available outside of the middleware stack.
      #   raise Faraday::TimeoutError, e
      end

      private  
      
      def perform_request(env)
        if parallel?(env)
          env[:parallel_manager].queue request(env)
        else
          request(env).run
        end
      end

      def request(env)
        read_body env

        req = typhoeus_request(env)

        configure_ssl     req, env
        configure_proxy   req, env
        configure_timeout req, env
        configure_socket  req, env

        req.on_complete do |resp|
          if resp.timed_out?
            env[:typhoeus_timed_out] = true
            unless parallel?(env)
              raise Faraday::TimeoutError, "request timed out"
            end
          elsif (resp.response_code == 0) || ((resp.return_code != :ok) && !resp.mock?)
            env[:typhoeus_connection_failed] = true
            env[:typhoeus_return_message] = resp.return_message
            unless parallel?(env)
              raise Faraday::ConnectionFailed, resp.return_message
            end
          end

          save_response(env, resp.code, resp.body) do |response_headers|
            response_headers.parse resp.response_headers
          end
          # in async mode, :response is initialized at this point
          env[:response].finish(env) if parallel?(env)
        end

        req
      end

      def typhoeus_request(env)
        opts = {
          :method => env[:method],
          :body => env[:body],
          :headers => env[:request_headers]
        }.merge(@connection_options)

        ::Typhoeus::Request.new(env[:url].to_s, opts)
      end

      def read_body(env)
        env[:body] = env[:body].read if env[:body].respond_to? :read
      end

      def configure_ssl(req, env)
        ssl = env[:ssl]

        verify_p = (ssl && ssl.fetch(:verify, true))

        ssl_verifyhost = verify_p ? 2 : 0
        req.options[:ssl_verifyhost] = ssl_verifyhost
        req.options[:ssl_verifypeer] = verify_p
        req.options[:sslversion] = ssl[:version]     if ssl[:version]
        req.options[:sslcert]    = ssl[:client_cert] if ssl[:client_cert]
        req.options[:sslkey]     = ssl[:client_key]  if ssl[:client_key]
        req.options[:cainfo]     = ssl[:ca_file]     if ssl[:ca_file]
        req.options[:capath]     = ssl[:ca_path]     if ssl[:ca_path]
        client_cert_passwd_key   = [:client_cert_passwd, :client_certificate_password].detect { |name| ssl.key?(name) }
        req.options[:keypasswd]  = ssl[client_cert_passwd_key] if client_cert_passwd_key
      end

      def configure_proxy(req, env)
        proxy = env[:request][:proxy]
        return unless proxy

        req.options[:proxy] = "#{proxy[:uri].scheme}://#{proxy[:uri].host}:#{proxy[:uri].port}"

        if proxy[:user] && proxy[:password]
          req.options[:proxyauth] = :any
          req.options[:proxyuserpwd] = "#{proxy[:user]}:#{proxy[:password]}"
        end
      end

      def configure_timeout(req, env)
        env_req = env[:request]
        req.options[:timeout_ms] = (env_req[:timeout] * 1000).to_i             if env_req[:timeout]
        req.options[:connecttimeout_ms] = (env_req[:open_timeout] * 1000).to_i if env_req[:open_timeout]
      end

      def configure_socket(req, env)
        if bind = env[:request][:bind]
          req.options[:interface] = bind[:host]
        end
      end

      def parallel?(env)
        !!env[:parallel_manager]
      end
    end
  end
end