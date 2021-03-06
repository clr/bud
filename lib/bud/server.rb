require 'socket'

class Bud::BudServer < EM::Connection #:nodoc: all
  def initialize(bud, channel_filter)
    @bud = bud
    @channel_filter = channel_filter
    @filter_buf = {}
    @pac = MessagePack::Unpacker.new
    super
  end

  def receive_data(data)
    # Feed the received data to the deserializer
    @pac.feed data

    # streaming deserialize
    @pac.each do |obj|
      message_received(obj)
    end

    # apply the channel filter to each channel's pending tuples
    buf_leftover = {}
    @filter_buf.each do |tbl_name, buf|
      if @channel_filter
        accepted, saved = @channel_filter.call(tbl_name, buf)
      else
        accepted = buf
        saved = []
      end

      unless accepted.empty?
        @bud.inbound[tbl_name] ||= []
        @bud.inbound[tbl_name] += accepted
      end
      buf_leftover[tbl_name] = saved unless saved.empty?
    end
    @filter_buf = buf_leftover

    begin
      @bud.tick_internal if @bud.running_async
    rescue Exception
      # If we raise an exception here, EM dies, which causes problems (e.g.,
      # other Bud instances in the same process will crash). Ignoring the
      # error isn't best though -- we should do better (#74).
      puts "Exception handling network messages: #{$!}"
      puts "Inbound messages:"
      @bud.inbound.each do |chn_name, t|
        puts "    #{t.inspect} (channel: #{chn_name})"
      end
      @bud.inbound.clear
    end

    @bud.rtracer.sleep if @bud.options[:rtrace]
  end

  def message_received(obj)
    unless (obj.class <= Array and obj.length == 2 and
            @bud.tables.include?(obj[0].to_sym) and obj[1].class <= Array)
      raise Bud::Error, "bad inbound message of class #{obj.class}: #{obj.inspect}"
    end

    @bud.rtracer.recv(obj) if @bud.options[:rtrace]
    @filter_buf[obj[0].to_sym] ||= []
    @filter_buf[obj[0].to_sym] << obj[1]
  end
end
