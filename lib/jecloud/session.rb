module JeCloud
class Session

  attr_reader :next_attempt

  BACKOFF_DELAYS = [1, 2, 3, 5, 8, 13, 21, 34, 55, 89, 144, 233, 377, 610, 987, 1597, 2584, 4181, 6765, 10946, 17711, 28657, 46368, 75025]

  def initialize failures
    @failures = failures
    @next_attempt = nil
    @any_actions_executed = false
  end

  def any_actions_executed?
    @any_actions_executed
  end

  def action name, options={}, &block
    raise "action must have :if or :unless condition specified" unless options.include?(:if) || options.include?(:unless)

    options = { :if => true, :unless => false }.merge(options)
    unless options.if && !options.unless
      $log.debug "Not needed: #{name}"
      return
    end
    run_action_or_check name, &block
    @any_actions_executed = true  # got here, so action succeeded
  end

  # check results should be cached eventually, but for now run them every time
  def check name, options={}, &block
    options = { :if => true, :unless => false }.merge(options)
    unless options.if && !options.unless
      $log.debug "Not needed: #{name}"
      return
    end

    run_action_or_check name, &block
  end

private

  def run_action_or_check name
    failure = @failures.delete(name) || Hashie::Mash.new
    now = Time.now.to_i
    next_attempt = failure.last && failure.last + failure.delay
    if next_attempt && next_attempt > now
      $log.debug "Skipping action #{name} for #{failure.last + failure.delay - now} more seconds"
      @failures[name] = failure
      @next_attempt = [@next_attempt || next_attempt, next_attempt].min
      throw :failed
    else
      $log.debug "Starting: #{name}"
      begin
        result = yield
        $log.info "Succeeded: #{name}"
      rescue Exception => e
        message = "#{e.class.name}: #{e.message}"
        failure.first ||= now
        failure.last = now
        failure['count'] = (failure['count'] || 0) + 1
        failure.message = message
        failure.delay = BACKOFF_DELAYS.find { |delay| delay > (failure.delay || 0) } || BACKOFF_DELAYS.last
        @failures[name] = failure

        next_attempt = failure.last + failure.delay
        @next_attempt = [@next_attempt || next_attempt, next_attempt].min

        $log.error "Action #{name} failed with #{message}, will retry in #{failure.delay} seconds"
        $stderr.puts e.backtrace
        throw :failed
      end
    end
    return result
  end

end
end
