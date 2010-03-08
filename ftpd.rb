# coding: utf-8

require 'rubygems'
gem 'eventmachine', '>=0.12.8'
require 'eventmachine'
require 'socket'
require 'stringio'

# A demo FTP server, built on top of the EventMacine gem.
#
# This isn't a useful FTP server. It has hard coded authentication and an
# emulated directory structure. I hope it serves as a useful piece of sample code
# regardless. See the README for more info.
#
# license: MIT License // http://www.opensource.org/licenses/mit-license.php
# copyright: (c) 2006 James Healy
#
class FTPServer < EM::Protocols::LineAndTextProtocol

  LBRK = "\r\n"
  COMMANDS = %w[quit type user retr stor port cdup cwd dele rmd pwd list size
                syst mkd pass xcup xpwd xcwd xrmd rest allo nlst pasv allo help
                noop mode rnfr rnto stru]
  FILE_ONE = "This is the first file available for download.\n\nBy James"
  FILE_TWO = "This is the file number two.\n\n2009-03-21"
  attr_reader :root, :name_prefix
  attr_accessor :datasocket

  # callback recognised by EventMachine that is called when a new connection
  # is initiated
  #
  def post_init
    @mode   = :binary
    @name_prefix = "/"

    send_response "220 FTP server (rftpd) ready"
  end

  # I used to implement the standard receive_data callback, then buffer data
  # until I had a complete line. Now I just base my server on the
  # LineAndTextProtocol class that is distributed with EM. It handles the
  # buffering for me and calls this receive_line() method once the line is
  # complete
  #
  def receive_line(str)
    puts "line: #{str}"
    # break the request into command and parameter components
    cmd, param = parse_request(str)

    # if the command is contained in the whitelist, and there is a method
    # to handle it, call it. Otherwise send an appropriate response to the
    # client
    puts
    puts "Request : #{cmd}(#{param})"
    if COMMANDS.include?(cmd) && self.respond_to?("cmd_#{cmd}".to_sym, true)
      self.__send__("cmd_#{cmd}".to_sym, param)
    else
      bad_command(cmd, param)
    end
  end

  private

  def build_path(filename = nil)
    if filename && filename[0,1] == "/"
      path = File.expand_path(filename)
    elsif filename
      path = File.expand_path("#{@name_prefix}/#{filename}")
    else
      path = File.expand_path(@name_prefix)
    end
    path.gsub(/\/+/,"/")
  end

  # split a client's request into command and parameter components
  def parse_request(data)
    data.strip!
    space = data.index(" ")
    if space
      cmd = data[0, space]
      param = data[space+1, data.length - space]
      param = nil if param.strip.size == 0
    else
      cmd = data
      param = nil
    end

    return cmd.downcase, param
  end


  # respond to an unrecognised request
  def bad_command(cmd, param)
    send_response "500 Sorry, I don't understand #{cmd.upcase}"
  end

  # close the datasocket this connection is using
  def close_datasocket
    if @datasocket
      @datasocket.close_connection_after_writing
      @datasocket = nil
    end

    # stop listening for data socket connections, we have one
    if @listen_sig
      FTPPassiveDataSocket.stop(@listen_sig)
      @listen_sig = nil
    end
  end

  # handle the deprecated ALLO FTP command.
  def cmd_allo(param)
    send_response "200"
  end

  # go up a directory, really just an alias
  def cmd_cdup(param)
    send_unauthorised and return unless logged_in?
    cmd_cwd("..")
  end

  # As per RFC1123, XCUP is a synonym for CDUP
  alias cmd_xcup cmd_cdup

  # change directory
  def cmd_cwd(param)
    send_unauthorised and return unless logged_in?
    path = build_path(param)

    puts "************* '#{path}"
    case path
    when "/", "/files"
      @name_prefix = path
      send_response "250 Directory changed to #{path}"
    else
      send_response "550 Directory not found"
    end
  end

  # As per RFC1123, XCWD is a synonym for CWD
  alias cmd_xcwd cmd_cwd

  # delete a file
  def cmd_dele(param)
    send_permission_denied
  end

  # handle the HELP FTP command by sending a list of available commands.
  def cmd_help(param)
    commands = COMMANDS
    commands.sort!
    send_response "214- The following commands are recognized."
    i   = 1
    str = "  "
    commands.each do |c|
      str += "#{c}"
      str += "\t\t"
      str += LBRK << "  " if (i % 3) == 0
      i   += 1
    end
    send_response str, true
  end

  # make directory
  def cmd_mkd(param)
    send_permission_denied
  end

  # the original FTP spec had various options for hosts to negotiate how data
  # would be sent over the data socket, In reality these days (S)tream mode
  # is all that is used for the mode - data is just streamed down the data
  # socket unchanged.
  #
  def cmd_mode(param)
    send_unauthorised and return unless logged_in?
    send_param_required and return if param.nil?
    if param.upcase.eql?("S")
      send_response "200 OK"
    else
      send_response "504 MODE is an obsolete command"
    end
  end

  # return a listing of the current directory, one per line, each line
  # separated by the standard FTP EOL sequence. The listing is returned
  # to the client over a data socket.
  #
  def cmd_nlst(param)
    send_unauthorised and return unless logged_in?
    send_response "150 Opening ASCII mode data connection for file list"

    case build_path(param)
    when "/"
      files = %w[. .. files one.txt]
    when "/files"
      files = %w[. .. two.txt]
    end

    send_outofband_data(files.join(LBRK) << LBRK)
  end

  # return a detailed list of files and directories, seperated by the
  # FTP line break sequence
  def cmd_list(param)
    send_unauthorised and return unless logged_in?
    send_response "150 Opening ASCII mode data connection for file list"

    timestr = Time.now.strftime("%b %d %H:%M")
    lines = []
    lines << "drwxr-xr-x 1 owner group            0 #{timestr} ."
    lines << "drwxr-xr-x 1 owner group            0 #{timestr} .."

    path = build_path(param)
    case path
    when "/"
      lines << "drwxr-xr-x 1 owner group            0 #{timestr} files"
      lines << "-rwxr-xr-x 1 owner group#{FILE_ONE.size.to_s.rjust(13)} #{timestr} one.txt"
    when "/files"
      lines << "-rwxr-xr-x 1 owner group#{FILE_TWO.size.to_s.rjust(13)} #{timestr} two.txt"
    end

    send_outofband_data(lines.join(LBRK) << LBRK)
  end

  # handle the NOOP FTP command. This is essentially a ping from the client
  # so we just respond with an empty 200 message.
  def cmd_noop(param)
    send_response "200"
  end

  # handle the PASS FTP command. This is the second stage of a user logging in
  def cmd_pass(param)
    send_response "202 User already logged in" and return if @user
    send_param_required and return if param.nil?
    send_response "530 password with no username" and return if @requested_user.nil?

    # return an error message if:
    #  - the specified username isn't in our system
    #  - the password is wrong
    if @requested_user != "test" || param != "1234"
      @user = nil
      send_response "530 incorrect login. not logged in."
      return
    end

    @name_prefix = "/"
    @user = @requested_user
    @requested_user = nil
    send_response "230 OK, password correct"
  end

  # Passive FTP. At the clients request, listen on a port for an incoming
  # data connection. The listening socket is opened on a random port, so
  # the host and port is sent back to the client on the control socket.
  def cmd_pasv(param)
    send_unauthorised and return unless logged_in?

    # close any existing data socket
    close_datasocket

    # grab the host/address the current connection is
    # operating on
    host = Socket.unpack_sockaddr_in( self.get_sockname ).last

    # open a listening socket on the appropriate host
    # and on a random port
    @listen_sig = FTPPassiveDataSocket.start(host, self)
    port = FTPPassiveDataSocket.get_port(@listen_sig)

    # let the client know where to connect
    p1 = (port / 256).to_i
    p2 = port % 256

    send_response "227 Entering Passive Mode (" + host.split(".").join(",") + ",#{p1},#{p2})"
  end

  # Active FTP. An alternative to Passive FTP. The client as a listening socket
  # open, waiting for us to connect and establish a data socket. Attempt to
  # open a connection to the host and port they specify and save the connection,
  # ready for either end to send something down it.
  def cmd_port(param)
    send_unauthorised and return unless logged_in?
    send_param_required and return if param.nil?

    nums = param.split(',')
    port = nums[4].to_i * 256 + nums[5].to_i
    host = nums[0..3].join('.')
    close_datasocket

    puts "connecting to client #{host} on #{port}"
    @datasocket = FTPActiveDataSocket.open(host, port)

    puts "Opened active connection at #{host}:#{port}"
    send_response "200 Connection established (#{port})"
  rescue
    puts "Error opening data connection to #{host}:#{port}"
    send_response "425 Data connection failed"
  end

  # return the current directory
  def cmd_pwd(param)
    send_unauthorised and return unless logged_in?
    send_response "257 \"#{@name_prefix}\" is the current directory"
  end

  # As per RFC1123, XPWD is a synonym for PWD
  alias cmd_xpwd cmd_pwd

  # resume downloads
  def cmd_rest(param)
    send_response "500 Feature not implemented"
  end

  # send a file to the client
  def cmd_retr(param)
    send_unauthorised and return unless logged_in?
    send_param_required and return if param.nil?

    path = build_path(param)

    # if file exists, send it to the client
    case path
    when "/one.txt"
      send_response "150 Data transfer starting"
      send_outofband_data(FILE_ONE)
    when "/files/two.txt"
      send_response "150 Data transfer starting"
      send_outofband_data(FILE_TWO)
    else
      # otherwise, inform the user the file doesn't exist
      send_response "551 file not available"
    end
  end

  # delete a directory
  def cmd_rmd(param)
    send_permission_denied
  end

  # As per RFC1123, XRMD is a synonym for RMD
  alias cmd_xrmd cmd_rmd

  # rename a file
  def cmd_rnfr(param)
    send_permission_denied
  end

  # rename a file
  def cmd_rnto(param)
    send_permission_denied
  end

  # handle the QUIT FTP command by closing the connection
  def cmd_quit(param)
    send_response "221 Bye"
    close_datasocket
    close_connection_after_writing
  end

  # return the size of a file in bytes
  def cmd_size(param)
    # safety checks to make sure clients can't request files they're
    # not allowed to
    send_unauthorised and return unless logged_in?
    send_param_required and return if param.nil?

    path = build_path(param)

    # if file exists, send it to the client
    if path == "/one.txt"
      send_response "213 #{FILE_ONE.size}"
    elsif path == "/files/two.txt"
      send_response "213 #{FILE_TWO.size}"
    else
      # otherwise, inform the user the file doesn't exist
      send_response "450 file not available"
    end
  end

  # save a file from a client
  def cmd_stor(param)
    send_unauthorised and return unless logged_in?
    send_param_required and return if param.nil?

    # let the client know we're ready to start
    send_response "150 Data transfer starting"

    filename = build_path(param)

    # the client is going to spit some data at us over the data socket. Add
    # a callback that will execute when the client closes the socket. We more
    # or less just send an ACK back over the control port
    set_callback(filename)
  end

  # only set callback when we have a valid datasocket
  def set_callback(filename)
    if @datasocket.nil?
      EventMachine.next_tick { send_callback(filename) }
      return
    end

    @datasocket.callback do |data|
      # Since we're emulating an directory structure, don't actually save the
      # file.
      #File.open(filename, 'w') do |file|
      #  file.write data
      #  send_response "200 OK, received #{data.size} bytes"
      #end
      send_response "200 OK, received #{data.size} bytes"
    end
  end

  # like the MODE and TYPE commands, stru[cture] dates back to a time when the FTP
  # protocol was more aware of the content of the files it was transferring, and
  # would sometimes be expected to translate things like EOL markers on the fly.
  #
  # These days files are sent unmodified, and F(ile) mode is the only one we
  # really need to support.
  def cmd_stru(param)
    send_param_required and return if param.nil?
    send_unauthorised and return unless logged_in?
    if param.upcase.eql?("F")
      send_response "200 OK"
    else
      send_response "504 STRU is an obsolete command"
    end
  end

  # return the name of the server
  def cmd_syst(param)
    send_response "530 Not logged in" and return unless @user
    send_response "215 UNIX Type: L8"
  end

  # like the MODE and STRU commands, TYPE dates back to a time when the FTP
  # protocol was more aware of the content of the files it was transferring, and
  # would sometimes be expected to translate things like EOL markers on the fly.
  #
  # Valid options were A(SCII), I(mage), E(BCDIC) or LN (for local type). Since
  # we plan to just accept bytes from the client unchanged, I think Image mode is
  # adequate. The RFC requires we accept ASCII mode however, so accept it, but
  # ignore it.
  def cmd_type(param)
    send_unauthorised and return unless logged_in?
    send_param_required and return if param.nil?
    if param.upcase.eql?("A")
      send_response "200 Type set to ASCII"
    elsif param.upcase.eql?("I")
      send_response "200 Type set to binary"
    else
      send_response "500 Invalid type"
    end
  end

  # handle the USER FTP command. This is a user attempting to login.
  # we simply store the requested user name as an instance variable
  # and wait for the password to be submitted before doing anything
  def cmd_user(param)
    send_param_required and return if param.nil?
    send_response("500 Already logged in") and return if @user
    @requested_user = param
    send_response "331 OK, password required"
  end

  # send data to the client
  def send_outofband_data(data)
    if @datasocket.nil?
      EventMachine.next_tick { send_outofband_data(data)}
      return
    end

    data = StringIO.new(data) if data.kind_of?(String)
    begin
      bytes = 0
      data.each do |line|
        @datasocket.send_data(line)
        bytes += line.length
      end
      send_response "226 Closing data connection, sent #{bytes} bytes"
    ensure
      close_datasocket
      data.close if data.class == File
    end
  rescue
    send_response "425 Error establishing connection"
  end

  # all responses from an FTP server end with \r\n, so wrap the
  # send_data callback
  def send_response(msg, no_linebreak = false)
    puts msg
    msg += LBRK unless no_linebreak
    send_data msg
  end

  def send_param_required
    send_response "553 action aborted, required param missing"
  end

  def send_permission_denied
    send_response "550 Permission denied"
  end

  def send_illegal_params
    send_response "553 action aborted, illegal params"
  end

  def send_unauthorised
    send_response "530 Not logged in"
  end

  def logged_in?
    @user ? true : false
  end
end

# An eventmachine module for connecting to a remote
# port and downloading a file
#
class FTPActiveDataSocket < EventMachine::Connection
  include EM::Deferrable

  def self.open(host, port)
    EventMachine.connect(host, port, self)
  end

  def data
    @data ||= ""
  end

  def receive_data(chunk)
    data << chunk
  end

  def unbind
    self.set_deferred_status :succeeded, @data
  end
end

# An eventmachine module for opening a socket for the client to connect
# to and send a file
#
class FTPPassiveDataSocket < EventMachine::Connection
  include EM::Deferrable

  attr_reader :data

  def self.start(host, control_server)
    EventMachine.start_server(host, 0, self) do |conn|
      control_server.datasocket = conn
    end
  end

  # stop the server with signature "sig"
  def self.stop(sig)
    EventMachine.stop_server(sig)
  end

  # return the port the server with signature "sig" is listening on
  #
  def self.get_port(sig)
    Socket.unpack_sockaddr_in( EM.get_sockname( sig ) ).first
  end

  def data
    @data ||= ""
  end

  def receive_data(chunk)
    data << chunk
  end

  def unbind
    self.set_deferred_status :succeeded, @data
  end
end

# if this file was run directly, spin up eventmachine on port 21
if $0 == __FILE__

  # signal handling, ensure we exit gracefully
  trap "SIGCLD", "IGNORE"
  trap "INT" do
    puts "exiting..."
    puts
    EventMachine::run
    exit
  end

  uid, gid = *ARGV
  uid = uid.to_i if uid
  gid = gid.to_i if gid

  EventMachine::run do
    puts "Starting ftp server on 0.0.0.0:21"
    EventMachine::start_server("0.0.0.0", 21, FTPServer)

    # once the server has spun up, change the owner of process
    # for security reasons. I don't even trust my own code to
    # run as root, let alone my code that's running an Internet
    # visible network service.
    if gid && Process.gid == 0
      Process.gid = gid
    end
    if uid && Process.euid == 0
      Process::Sys.setuid(uid)
    end

  end
end
