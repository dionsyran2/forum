# frozen_string_literal: true

require 'method_profiler'
require 'middleware/anonymous_cache'

class Middleware::RequestTracker

  @@detailed_request_loggers = nil
  @@ip_skipper = nil

  # You can add exceptions to our app rate limiter in the app.yml ENV section.
  # example:
  #
  # env:
  #   DISCOURSE_MAX_REQS_PER_IP_EXCEPTIONS: >-
  #     14.15.16.32/27
  #     216.148.1.2
  #
  STATIC_IP_SKIPPER = ENV['DISCOURSE_MAX_REQS_PER_IP_EXCEPTIONS']&.split&.map { |ip| IPAddr.new(ip) }

  # register callbacks for detailed request loggers called on every request
  # example:
  #
  # Middleware::RequestTracker.detailed_request_logger(->|env, data| do
  #   # do stuff with env and data
  # end
  def self.register_detailed_request_logger(callback)
    MethodProfiler.ensure_discourse_instrumentation!
    (@@detailed_request_loggers ||= []) << callback
  end

  def self.unregister_detailed_request_logger(callback)
    @@detailed_request_loggers.delete(callback)
    if @@detailed_request_loggers.length == 0
      @detailed_request_loggers = nil
    end
  end

  # used for testing
  def self.unregister_ip_skipper
    @@ip_skipper = nil
  end

  # Register a custom `ip_skipper`, a function that will skip rate limiting
  # for any IP that returns true.
  #
  # For example, if you never wanted to rate limit 1.2.3.4
  #
  # ```
  # Middleware::RequestTracker.register_ip_skipper do |ip|
  #  ip == "1.2.3.4"
  # end
  # ```
  def self.register_ip_skipper(&blk)
    raise "IP skipper is already registered!" if @@ip_skipper
    @@ip_skipper = blk
  end

  def initialize(app, settings = {})
    @app = app
  end

  def self.log_request(data)
    status = data[:status]
    track_view = data[:track_view]

    if track_view
      if data[:is_crawler]
        ApplicationRequest.increment!(:page_view_crawler)
        WebCrawlerRequest.increment!(data[:user_agent])
      elsif data[:has_auth_cookie]
        ApplicationRequest.increment!(:page_view_logged_in)
        ApplicationRequest.increment!(:page_view_logged_in_mobile) if data[:is_mobile]
      elsif !SiteSetting.login_required
        ApplicationRequest.increment!(:page_view_anon)
        ApplicationRequest.increment!(:page_view_anon_mobile) if data[:is_mobile]
      end
    end

    ApplicationRequest.increment!(:http_total)

    if status >= 500
      ApplicationRequest.increment!(:http_5xx)
    elsif data[:is_background]
      ApplicationRequest.increment!(:http_background)
    elsif status >= 400
      ApplicationRequest.increment!(:http_4xx)
    elsif status >= 300
      ApplicationRequest.increment!(:http_3xx)
    elsif status >= 200
      ApplicationRequest.increment!(:http_2xx)
    end
  end

  def self.get_data(env, result, timing)
    status, headers = result
    status = status.to_i

    helper = Middleware::AnonymousCache::Helper.new(env)
    request = Rack::Request.new(env)

    env_track_view = env["HTTP_DISCOURSE_TRACK_VIEW"]
    track_view = status == 200
    track_view &&= env_track_view != "0" && env_track_view != "false"
    track_view &&= env_track_view || (request.get? && !request.xhr? && headers["Content-Type"] =~ /text\/html/)
    track_view = !!track_view

    h = {
      status: status,
      is_crawler: helper.is_crawler?,
      has_auth_cookie: helper.has_auth_cookie?,
      is_background: !!(request.path =~ /^\/message-bus\// || request.path =~ /\/topics\/timings/),
      is_mobile: helper.is_mobile?,
      track_view: track_view,
      timing: timing,
      queue_seconds: env['REQUEST_QUEUE_SECONDS']
    }

    if h[:is_crawler]
      user_agent = env['HTTP_USER_AGENT']
      if user_agent && (user_agent.encoding != Encoding::UTF_8)
        user_agent = user_agent.encode("utf-8")
        user_agent.scrub!
      end
      h[:user_agent] = user_agent
    end

    if cache = headers["X-Discourse-Cached"]
      h[:cache] = cache
    end

    h
  end

  def log_request_info(env, result, info)
    # we got to skip this on error ... its just logging
    data = self.class.get_data(env, result, info) rescue nil

    if data
      if result && (headers = result[1])
        headers["X-Discourse-TrackView"] = "1" if data[:track_view]
      end

      if @@detailed_request_loggers
        @@detailed_request_loggers.each { |logger| logger.call(env, data) }
      end

      log_later(data)
    end
  end

  def self.populate_request_queue_seconds!(env)
    if !env['REQUEST_QUEUE_SECONDS']
      if queue_start = env['HTTP_X_REQUEST_START']
        queue_start = if queue_start.start_with?("t=")
          queue_start.split("t=")[1].to_f
        else
          queue_start.to_f / 1000.0
        end
        queue_time = (Time.now.to_f - queue_start)
        env['REQUEST_QUEUE_SECONDS'] = queue_time
      end
    end
  end

  def call(env)
    result = nil
    log_request = true

    # doing this as early as possible so we have an
    # accurate counter
    ::Middleware::RequestTracker.populate_request_queue_seconds!(env)

    request = Rack::Request.new(env)

    if available_in = rate_limit(request)
      return [
        429,
        { "Retry-After" => available_in.to_s },
        ["Slow down, too many requests from this IP address"]
      ]
    end

    env["discourse.request_tracker"] = self

    MethodProfiler.start
    result = @app.call(env)
    info = MethodProfiler.stop

    # possibly transferred?
    if info && (headers = result[1])
      headers["X-Runtime"] = "%0.6f" % info[:total_duration]

      if GlobalSetting.enable_performance_http_headers
        if redis = info[:redis]
          headers["X-Redis-Calls"] = redis[:calls].to_s
          headers["X-Redis-Time"] = "%0.6f" % redis[:duration]
        end
        if sql = info[:sql]
          headers["X-Sql-Calls"] = sql[:calls].to_s
          headers["X-Sql-Time"] = "%0.6f" % sql[:duration]
        end
        if queue = env['REQUEST_QUEUE_SECONDS']
          headers["X-Queue-Time"] = "%0.6f" % queue
        end
      end
    end

    if env[Auth::DefaultCurrentUserProvider::BAD_TOKEN] && (headers = result[1])
      headers['Discourse-Logged-Out'] = '1'
    end

    result
  ensure
    if (limiters = env['DISCOURSE_RATE_LIMITERS']) && env['DISCOURSE_IS_ASSET_PATH']
      limiters.each(&:rollback!)
      env['DISCOURSE_ASSET_RATE_LIMITERS'].each do |limiter|
        begin
          limiter.performed!
        rescue RateLimiter::LimitExceeded
          # skip
        end
      end
    end
    log_request_info(env, result, info) unless !log_request || env["discourse.request_tracker.skip"]
  end

  def is_private_ip?(ip)
    ip = IPAddr.new(ip) rescue nil
    !!(ip && (ip.private? || ip.loopback?))
  end

  def rate_limit(request)
    if (
      GlobalSetting.max_reqs_per_ip_mode == "block" ||
      GlobalSetting.max_reqs_per_ip_mode == "warn" ||
      GlobalSetting.max_reqs_per_ip_mode == "warn+block"
    )

      ip = request.ip

      if !GlobalSetting.max_reqs_rate_limit_on_private
        return false if is_private_ip?(ip)
      end

      return false if @@ip_skipper&.call(ip)
      return false if STATIC_IP_SKIPPER&.any? { |entry| entry.include?(ip) }

      limiter10 = RateLimiter.new(
        nil,
        "global_ip_limit_10_#{ip}",
        GlobalSetting.max_reqs_per_ip_per_10_seconds,
        10,
        global: true,
        aggressive: true
      )

      limiter60 = RateLimiter.new(
        nil,
        "global_ip_limit_60_#{ip}",
        GlobalSetting.max_reqs_per_ip_per_minute,
        60,
        global: true,
        aggressive: true
      )

      limiter_assets10 = RateLimiter.new(
        nil,
        "global_ip_limit_10_assets_#{ip}",
        GlobalSetting.max_asset_reqs_per_ip_per_10_seconds,
        10,
        global: true
      )

      request.env['DISCOURSE_RATE_LIMITERS'] = [limiter10, limiter60]
      request.env['DISCOURSE_ASSET_RATE_LIMITERS'] = [limiter_assets10]

      warn = GlobalSetting.max_reqs_per_ip_mode == "warn" || GlobalSetting.max_reqs_per_ip_mode == "warn+block"

      if !limiter_assets10.can_perform?
        if warn
          Discourse.warn("Global asset IP rate limit exceeded for #{ip}: 10 second rate limit", uri: request.env["REQUEST_URI"])
        end

        if GlobalSetting.max_reqs_per_ip_mode != "warn"
          return limiter_assets10.seconds_to_wait(Time.now.to_i)
        else
          return false
        end
      end

      begin
        type = 10
        limiter10.performed!

        type = 60
        limiter60.performed!

        false
      rescue RateLimiter::LimitExceeded => e
        if warn
          Discourse.warn("Global IP rate limit exceeded for #{ip}: #{type} second rate limit", uri: request.env["REQUEST_URI"])
          if GlobalSetting.max_reqs_per_ip_mode != "warn"
            e.available_in
          else
            false
          end
        else
          e.available_in
        end
      end
    end
  end

  def log_later(data)
    Scheduler::Defer.later("Track view") do
      unless Discourse.pg_readonly_mode?
        self.class.log_request(data)
      end
    end
  end
end
