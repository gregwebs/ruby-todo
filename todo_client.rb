#!/usr/bin/env ruby
# == Actions
#
#   a[dd] item text [state_tag] [context_tags] [tags] [d[ue]=date] [-- note text]
#     state_tag: [:next|:wait|:maybe] 
#     tags: :tag1 [:tag2 ...]
#     context_tags: @context1 [@context2 ...]
#
#   e[dit] [filter]
#
#   d[elete]|rm [filter]
#
#   r[estore] [filter]
#     restore item from done list
#
#   l[ist]: [filter]
#     show todolist items
#
#   s[tate] next|wait|maybe|done [filter]
#     change just the state of items
#     changing the state to done is equivalant to the delete|rm option
#
#   n[ext]|w[ait]|m[aybe]|d[one] [filter]
#     show items in the given state
#
#   c[ontexts] [filter]
#     view tasks grouped by context
#
#   p[rojects] [filter]
#     view tasks grouped by project
#
#     filter: [item_search1 :tag_search AND item_search2]
#       no arguments will show the entire todo list.
#
#       * a filter uses the same syntax as item additions
#          "list :tag1" will search through tags for "tag1"
#       * filters may also include regular expression characters
#       * multiple filters of the same field are an OR of the filters
#       * perform AND of filters by inserting 'AND' between them

# Copyright Greg Weber      webs.dev  gmail
# License: GNU GPL

# Issues: -N --show-note does not work with --pdf or --html
#   no plans to fix it as of now
#   --server only on unix


# SYNTAX of command line parsing
ACTION_STATES = %w{next wait maybe} # i have also seen: todo, watch, later
TAG_START = ':'     # this character is removed
CONTEXT_START = '@' # this is kept
NOTE_SEPERATOR = '--'
PRIORITY = /^[0-9A-Z]$/
PRIORITY_MATCH = /:^[0-9A-Z]$/
DUE_MATCH = /(?:d|D)u?e?=(.+)/

CONTEXT_START_MATCH = '^(?=@).*'
PROJECT_START_MATCH = '^(?=[^@]).*'

HOST = '127.0.0.1'
PORT = 0
TIMEOUT = 10 # time to look for server (seconds)
DEFAULT_DISPLAY_FIELDS = [:item, :state, :tags, :PRI, :due]

require 'enumerator'

def main
  parse_command_line_options()
rescue 
  if defined? DRb # drb is loaded only when needed
    begin
      raise $! 
    rescue DRb::DRbConnError
      puts "todo_server.rb not running!"
      exit(-1)
    end
  else
    raise $! # drb never loaded
  end
end

=begin
def sleepy_timeout timeout, increment=0.1
  ret = nil
  steps = (timeout / increment).to_i
  steps_taken = steps.times do
    break if block_given? and (ret=yield)
  end

  return RuntimeError if steps_taken == steps
  ret
end
def quicktest
  it "should yield to given block and return the yielded value" do
    sleepy_timeout( 0.1, 0.1 ) { "foo" }.should == "foo"
  end
  it "should raise an error" do
    lambda{ sleepy_timeout( 0.1, 0.1 ) }.should raise_error
    lambda{ sleepy_timeout( 0.1, 0.1 ) { false } }.should raise_error
  end
end
=end

class Thread; def dead?; not alive?  end end

def remote_db
  %w[drb rinda/ring].each{|lib| require lib}
  DRb.start_service "druby://#{HOST}:#{PORT}" # uri not necessary (faster)

  begin
    require 'timeout'
    Timeout.timeout(TIMEOUT) do
      Rinda::RingFinger.primary.read([:name, :TodoDB, nil, nil])[2]
    end
  rescue Timeout::Error
    puts "trying to start todo_server.rb"
    if start_todo_server()
      ARGV.unshift $arg if defined?($arg) and $arg
      # has some problems trying to re-invoke main, this works
      exec "#{File.dirname(__FILE__)}/todo_client.rb #{ARGV.join(' ')}" rescue fail "problem starting todo_client.rb"
    else
      puts "todo_server.rb not running!  Run todo_server.rb or use the --local flag"
      exit(-1)
    end
    puts "todo server started"
  end
end

def start_todo_server
  return false if RUBY_PLATFORM =~ /win/ and RUBY_PLATFORM !~ /cygwin/

  if fork
    puts "starting the server takes a few ..."
    sleep 20
    return true
  else
    exec "#{File.dirname(__FILE__)}/todo_server.rb" rescue fail "problems with todo_server.rb"
  end
end

def connect_to_db
  if $local_connection
    require "#{File.dirname(__FILE__)}/todo_server.rb"
    start_db()

  else
    remote_db()
  end
end

def help
  ARGV.unshift '--help'
  TodoList.parse_list_options
end

###### HELPERS ############
# Object helpers taken from methodchain gem
class Object
  # yield or instance_eval based on the block arity
  def yield_or_eval &block
    case block.arity
    # ruby bug for -1
    when 0, -1 then instance_eval(&block)
    when 1     then yield(self)
    else            raise ArgumentError, "too many arguments required by block"
    end
  end

  # return self if self evaluates to false, otherwise
  # evaluate the block or return the default argument
  def then default=nil, &block
    if self
      block_given? ? (yield_or_eval(&block)) : (default || (fail \
        ArgumentError, "#then must be called with an argument or a block"))
    else
      self
    end
  end

  def tap( &block );
    yield_or_eval(&block) if block_given?
    self
  end
end

class Hash
  def map!
    each_pair do |k,v|
      self[k] = yield k, v
    end
  end

  def take(other, *keys)
    keys.each { |key| self[key] = other.delete key }
  end
  def compact!
    delete_if {|k,v| v.nil?}
  end
end

class Array
  def map_msg!(meth, *args)
    map! {|o| o.send(meth, *args) }
  end

  def split_join( sep=$; )
    map {|e| e.split(sep)}.flatten.join(sep)
  end
end

class String
  def split_join( sep=$; )
    split(sep).join(sep)
  end
end

module ParseDate
  Months = Hash.new
  %w[jan feb mar apr may jun jul aug sep oct nov dec].each_with_index do |mon,i|
    Months[mon] = i + 1
  end

  Days = %w[mon tue wed thu fri sat sun]

  def ParseDate.pre_parse_convert(string)
    # convert dash or space dividers to slashes
    string.gsub!('-','/') or string.gsub!(' ','/')

    # convert text month to decimal
    string = string.split('/', -1).map do |s|
      if s.to_i == 0
        Months[(s[0,3].downcase)]
      end || s
    end.join('/')

    # throw out the weekday - this will correctly re-parse a date when editing
    # since parsedate doesn't handle weekdays -- this is obviously not the best solution
    if Days.include?( (str=string.split('/')).first[0,3].downcase )
      string = str[1..-1].join('/')
    end

    # if just one number, assume it is the day of the current or next month
    if string.split('/', -1).size == 1
      if (day=string.to_i) > 0 and day <= 32
        t = Time.now
        current_day = t.day
        month = t.month
        month += 1 if ( current_day <= day )
        string = month.to_s << '/' << day.to_s
      end
    end

    string
  end
  def self.quicktest
    it "should convert month to number" do
      ParseDate.pre_parse_convert("/DEC/feb/").should == "/12/2/"
    end
  end

  # attempt to parse the due date and fill in missing values with current time
  # only fill in from bigger to the smallest time given
  # need a year, month, or day
  # return new array that can be joined to a string
  # do not show year
  def ParseDate.interpolate( string )
    require 'parsedate'
    string = ParseDate.pre_parse_convert(string)
    pd = ParseDate.parsedate(string, true)[0..-3]

    # year or month or day found
    if pd[0] or pd[1] or pd[2]

      # I think this is bad parsing by parsedate
      # recognize month/year
      if !pd.first and pd[2] and string =~ /^\d+(?:\/|-)(?:\d{4})(?: |$)/
          pd[0], pd[2] = pd[2], pd[0]
      end

      # assume first of the month
      pd[2] = 1 if !pd[2] and pd.first and pd[1]

      last_i = (pd.size-1) - (pd.reverse.each_with_index{|t,i| break i if t})
      start_i = last_i < 2 ? 1 : 0

      # parsedate is in the reverse order of Time#to_a
      now_t = Time.now
      now_t.to_a[0 .. pd.size-1].reverse.each_with_index do |t,i|
        pd[i] ||= t
      end

      new_t = Time.local(*pd)
      res = new_t.to_s.split(' ')[start_i..last_i]
      res << new_t.year.to_s if new_t.year != now_t.year
      return res

    else
      nil
    end
  end
  def self.quicktest
    it "should retrieve an american date" do
      interpolate( "5/07" ).should == ['Wed', 'May', '07']
      interpolate( "5 07" ).should == ['Wed', 'May', '07']
      interpolate( "5-07" ).should == ['Wed', 'May', '07']
      interpolate( "May/07" ).should == ['Wed', 'May', '07']
      interpolate( "3/5/07" ).should == ['Mon', 'Mar', '05', '2007']
      interpolate( "Mar/5/07" ).should == ['Mon', 'Mar', '05', '2007']
      interpolate( "5/2007" ).should == ['Tue', 'May', '01', '2007']
      interpolate( "3/5/2009" ).should == ['Thu', 'Mar', '05', '2009']
      interpolate( "9" )[2].should == '09'
    end
  end

  def ParseDate.interpolate_to_s( datestring )
    ParseDate.interpolate( datestring ).then {|res| res.join(' ') }
  end
end
##########################

def parse_todo_syntax( args=ARGV )
  tags, item, note = [], [], []
  note_field = false
  args = args.map{|a| a.split ' '}.flatten

  while( arg=args.shift )
    case arg[0,1]
    when CONTEXT_START           then tags.unshift arg
    when TAG_START               then tags.push arg[1..-1]
    else  case
          when (arg == NOTE_SEPERATOR) then note_field = !( note_field )
          when (note_field)            then note.push arg
          else item.push arg
          end
    end
  end

  # user can input due=date
  due = nil
  item.each_with_index do |text,i|
    text.match( DUE_MATCH ).then do |m|
      item.delete_at(i)
      due = ParseDate.interpolate_to_s(m[1]) || m[1]
      break
    end
  end

  # look for action states amongst the tags
  state = ACTION_STATES.find {|action| tags.delete(action) }

  # look for priority tag
  priorities, tags = tags.partition {|tag| tag.match(PRIORITY).then {|m| m[0]} }
  priority =  case priorities.size 
              when 0 then nil
              when 1 then priorities.first
              else fail "More than one priority given"
              end

  {:tags => tags, :item => item, :note => note, :due => due,
    :state => state, :PRI => priority }.map! do |k,v|
    if v.nil? or v.empty? then nil else v.split_join(' ') end
  end
end

def parse_add_args( args=ARGV )
  parsed = parse_todo_syntax( args )

  if (parsed[:item].to_s.empty?)
    input =
    if require 'readline' # addition or edit?
      if parsed.find {|k,v| !(v.to_s.empty?) } # text in fields other than item
        puts "please re-enter with item text" 
        $stdin.gets 
      else # user just entered 'todo add' to go into readline mode
        Readline.readline
      end
    else # edit
      puts "please re-enter with item text" 
      Readline.readline
    end

    return parse_add_args( input.split(' ') )
  end

  return parsed
end
def self.quicktest
  it "should parse the CL to a hash" do
    parse_add_args(["item"])[:item].should == "item"
    parse_add_args(["item","stuff"])[:item].should == "item stuff"
    parse_add_args(["item","#{TAG_START}tag"])[:tags].should == "tag"
    parse_add_args(["item","#{TAG_START}tag","#{TAG_START}tag2"])[:tags].should == "tag tag2"
    parse_add_args(["item","#{TAG_START}tag","#{CONTEXT_START}c"])[:tags].should == "#{CONTEXT_START}c tag"
    parse_add_args(["item","#{CONTEXT_START}c","#{TAG_START}tag"])[:tags].should == "#{CONTEXT_START}c tag"
    parse_add_args(["item","--","note","text"])[:note].should == "note text"
    parse_add_args(["item"])[:state].should == nil
    parse_add_args(["item","#{TAG_START}#{ACTION_STATES[0]}","#{CONTEXT_START}c"])[:state].should == "#{ACTION_STATES[0]}"
    parse_add_args(["item","due=date"])[:due].should == "date"
  end
end 

def record_to_input( record )
  entry = record[:item]
  [record[:state], record[:PRI]].each {|r| r.then {|s| entry << " :#{s}" } }
  record[:tags].then  {|tags| entry << ' ' << tags.gsub(/(?:^| )(?!@)/, ' :').lstrip}
  record[:due].then   {|d| entry << " due=#{d.split(' ').join('-')}" }
  record[:note].then  {|n| entry << " -- #{n}" }
  entry
end
def self.quicktest
  it "should convert a record to a command line enry" do
    entry = Struct.new( :item, :state, :tags, :due, :note )
    e = entry.new( "test text", "next", "@home TPS", "Today", "file TPS report" )
    record_to_input(e).should == "test text :next @home :TPS due=Today -- file TPS report"
  end
end

# strings to regexes, allow AND and not
def compile_queries( queries )
  queries.map! do |field, regexes|
    if (regexes)
      regexes = [regexes] unless regexes.is_a? Array

      if regexes.empty? then nil
      else
        reg, str = regexes.partition {|re| re.is_a? Regexp }

        negated = false
        reg.concat( ('(?:' <<
        # option to negate query with NOT
        str.map do |s|
          if negated
            negated = false
            '^(?:\s*(?!' << s << ')\S)+$'
          elsif s == 'NOT'
            negated = true
            nil
          else
            s
          end
        end.compact.join(')|(?:') << ')').
        split('|(?:AND)|').map { |q| Regexp.compile q } )
      end
    end end.compact!
end
def self.quicktest
  it "should compile regular expressions" do
    compile_queries(:foo => ["foo"]).should == {:foo => [/(?:foo)/]}
    compile_queries(:fb => ["foo","BAR"]).should == {:fb => [/(?:foo)|(?:BAR)/]}
    compile_queries(:fab => ["foo","AND","BAR"]).should == {:fab => [/(?:foo)/,/(?:BAR)/]}
  end
end

module RuportPrinter
  def self.method_and_file_ext( type )
    case type
    when :pdf  then [:to_pdf, ".pdf"]
    when :html then [:to_html, ".html"]
    else fail ArgumentError, "unknown ruport type"
    end
  end

  def self.write( table_or_group, output_type, filename )
    action, output_ext = RuportPrinter.method_and_file_ext( output_type )
    File.open( (filename << output_ext), 'w') do |fh|
      fh.print( table_or_group.send( action ) )
    end
  end

  def seperate_ruports( arrays, column_names, output_type, filename )
    c = :ruport_grouping_column 
    table_data = {:data => arrays, :column_names => column_names.unshift( c ) }
    ruport_output( output_type, table_data, filename, c) 
  end

  def ruport( output_type, table_data, filename, grouping=nil )
    require 'rubygems'; require 'ruport'
    table = Ruport::Data::Table.new( table_data )
    table = Ruport::Data::Grouping.new( table, :by => grouping ) if grouping
    RuportPrinter.write( table, output_type, filename )
  end
end


class TodoList
  include RuportPrinter

  #TODO - all these options are making for a lot of ugliness
  # - @report hash - options to do with output
  # - @query hash - keys are fields to query against in the result set, values are query arrays
  # - @table[:table] selects which table (or file) @table[:all] selects all files
  # - @selectors selects which fields will be present in the result set
  def initialize( options={} )
    db_connect = Thread.new { connect_to_db() }
    @query, @report, @table = Hash.new, Hash.new, Hash.new

    # parse command line before connecting to db
    options.merge!( TodoList.parse_list_options() ) unless options[:no_CL]

    @table.take( options, :all, :table )
    @table[:table] ||= :todo

    @query = compile_queries( parse_todo_syntax() ) if !(ARGV.empty?)
    options.delete(:queries).then {|s| @query.merge! compile_queries(s) }

    @report.take( options, :note, :quiet, :ruport )

    all_filters = (DEFAULT_DISPLAY_FIELDS + (@query.keys || []) )
    if @report[:note] then all_filters.push(:note)
    elsif all_filters.include? :note then @report[:note] = true 
    end
    all_filters.uniq!

    @selectors = all_filters
    @report[:filters] = all_filters.dup

    @db = db_connect.value
  end
  def self.quicktest
    before do
      # helper
      self.class.send( :define_method, :new_opt_merge_iv_get) do |merge,iv|
        new(@opt.merge(merge)).instance_variable_get(iv)
      end

      alias_method :orig_connect_to_db, :connect_to_db
      define_method( :connect_to_db ){ "db" }
      @opt = {:no_CL => true, }
    end
    after { alias_method :connect_to_db, :orig_connect_to_db }

    it "should create report options" do
      report = { :note => false, :quiet => true, :ruport => :pdf }
      new_opt_merge_iv_get(report, :@report).should == report.merge(:filters => DEFAULT_DISPLAY_FIELDS)
      report.merge(:note => true, :filters => (DEFAULT_DISPLAY_FIELDS + [:note]))
      new_opt_merge_iv_get(report, :@report).should == report.merge(:filters => DEFAULT_DISPLAY_FIELDS)
    end

    it "should compile query options" do
      report = { :note => false, :quiet => true, :ruport => :pdf }
      queries = {:test => %w[t e s t], :state => 'next'}
      new_opt_merge_iv_get({:queries => queries.dup},:@query).should == compile_queries(queries)
    end

    it "should create table options" do
      table = {:table => :todo, :all => nil}
      all = {:all => true}; done = {:table => :done}
      new(@opt).instance_variable_get(:@table).should == table
      new_opt_merge_iv_get(all,:@table).should == table.merge(all)
      new_opt_merge_iv_get(done,:@table).should == table.merge(done)
    end

    it "should create list selectors" do
      new(@opt).instance_variable_get(:@selectors).should == DEFAULT_DISPLAY_FIELDS
      new_opt_merge_iv_get({:note => true},:@selectors).should == (DEFAULT_DISPLAY_FIELDS + [:note])
      queries = {:queries => {:test => "foo"}}
      new_opt_merge_iv_get(queries,:@selectors).should == (DEFAULT_DISPLAY_FIELDS + [:test])
      queries = {:queries => {:test => nil}}
      new_opt_merge_iv_get(queries,:@selectors).should == (DEFAULT_DISPLAY_FIELDS )
    end
  end

  def self.report( options={} )
    new.report( options )
  end

  def report( options={} )
    # do not show maybe items by default
    @query[:state] ||= compile_queries(
      :state => ACTION_STATES.dup.tap{ delete('maybe') } )[:state]

    @report.merge! options
    res = ''
    if @table[:all]
      @table[:table] = :todo
      res << generate_report( list() ) << "\n"
      @table[:table] = :done
    end

    res << generate_report( list() )
  end
  def self.quicktest
    before(:all) do
      @opt = {:no_CL => true}
      self.class.send( :define_method, :new_opt_merge) do |merge|
        new(@opt.merge(merge))
      end
      alias_method :orig_generate_report, :generate_report
      define_method( :generate_report ){ @table[:table].to_s }
      alias_method :orig_connect_to_db, :connect_to_db
      define_method( :connect_to_db ) do
        c = Class.new { def list(*args) "db list" end }.new
      end
    end

    after(:all) do
      alias_method :generate_report, :orig_generate_report
      alias_method :connect_to_db, :orig_connect_to_db
    end

    it "should generate a report for each table" do
      new(@opt).report.should == "todo"
      new_opt_merge(:table => :todo).report().should == "todo"
      new_opt_merge(:table => :done).report().should == "done"
      new_opt_merge(:all => true).report().should == "todo\ndone"
      new_opt_merge(:all => true, :table => :done).report().should == "todo\ndone"
      new_opt_merge(:all => true, :table => :todo).report().should == "todo\ndone"
    end
  end

  def list( selectors=@selectors )
    @db.list( {:table => @table[:table], :selectors => selectors}, @query )
  end

private
  def generate_report( res_set, options={} )
    @report.merge! options unless options.empty?

    if ( res_set ).empty? then puts "no matches" unless @report[:quiet]
      ""
    elsif (type=@report[:ruport]) then generate_ruport( res_set, type )
      ""
    elsif @report[:note]
      report_with_notes( res_set )
    else
      res_set.to_s( @report )
    end
  end
  def self.quicktest
    before(:all) do
      alias_method :orig_generate_ruport, :generate_ruport
      define_method( :generate_ruport ){ "R" }
      alias_method :orig_report_with_notes, :report_with_notes
      define_method( :report_with_notes ){|r| "N"}
      @opt = {:no_CL => true, :quiet => true}
      alias_method :orig_connect_to_db, :connect_to_db
      define_method( :connect_to_db ){ "db" }
    end
    after(:all) do
      alias_method :generate_ruport, :orig_generate_ruport
      alias_method :report_with_notes, :orig_report_with_notes
      alias_method :connect_to_db, :orig_connect_to_db
    end

    it "should generate a report according to the options" do
      ["r"].class.send( :alias_method, :orig_to_s, :to_s )
      ["r"].class.send( :define_method, :to_s ) {|a| first.to_s }

      new(@opt.dup).send( :generate_report, ["r"] ).should == "r"
      ["r"].class.send( :alias_method, :to_s, :orig_to_s )

      new(@opt.dup).send( :generate_report, "" ).should == ""
      new(@opt.merge(:ruport => :pdf)).send( :generate_report, "r" ).should == ""
      new(@opt.merge(:note => true)).send( :generate_report, "r" ).should == "N"
    end
  end

  def generate_ruport( result_set, type )
    ruport( type, result_set.report_table(*(@report[:filters].compact)),
            @table[:table].to_s )
  end

  # insert notes below the line they belong too
  def report_with_notes( result_set )
    notes = result_set.note
    @report[:filters].delete :note
    q = @report.delete(:quiet)
      rpt = result_set.to_s(@report).split("\n")
    @report[:quiet] = q

    (q ? '' : (rpt[0..1].join("\n") << "\n")) <<
    rpt[2..-1].enum_with_index.map do |line, i|
      if (note=notes[i])
        line << "\n--   " << note
      else
        line
      end
    end.join("\n")
  end

public
  # prepend the regex string to command line args
  def self.seperate_reports( regex_string, selector=:tags )
    options = self.parse_list_options # remove flags from CL
    options[:queries] = { selector =>
      if   ARGV.empty? then [ regex_string ]
      else ARGV.map {|arg| regex_string + arg }
      end
    }

    self.new( options ).seperate_reports( selector )
  end

  # used for contexts and projects
  def seperate_reports( selector )
    res = ""
    @db.disable_gc do
      result_set = list()
      type = @report[:ruport]

      if @table[:all]
        fail "Invalid options for reporrting" if type
        @table[:table] = :done
        result_set.concat list()
      end

      if (type)
        ruport = []
        TodoList.query_result_set( result_set, @query ).each_pair do |field, records|
          result_set.clear.concat( records )
          ruport.concat( result_set.to_arrays( *@report[:filters] ).map! {|arr| arr.unshift field })
        end

        seperate_ruports( ruport, @report[:filters], type, @table[:table].to_s )

      else
        TodoList.query_result_set( result_set, @query ).
        each_pair do |field, records|
          result_set.clear.concat( records )
          res << "\n               #{field}\n" << generate_report( result_set )
        end
      end
    end
    res
  end

  # we are splitting tags on white space, and matching aginst
  # each one which is different from the normal sorting
  def self.query_result_set( result_set, queries )
    selector = queries.keys.first
    qys = queries.values.first

    Hash.new {|h,k| h[k] = []}.tap do |fields|
      result_set.each do |record|
        if (fieldtext = record[selector])
          fieldtext.split(' ').each do |text|
            if qys.all? { |q| text =~ q }
              fields[text].push( record.dup )
              break
            end end end end end
  end
  def self.quicktest
    it "should create a hash of fields to records" do
      fb = Struct.new :foo, :bar
      a = fb.new("foo", "bar");
      b = fb.new("foo bar", "z")
      c = fb.new("foo bars", "z")
      d = fb.new("bars foos", "z")
      result_set = [a,b,c,d]
      self.query_result_set( result_set, :foo => [/bar/] ).should == {"bar" => [b], "bars" => [c,d]}
    end
  end

  def session( mod_type, prompt, &block )
    @selectors.push :recno # deletion key, hidden from user
    mod_type = :delete_from_done if mod_type == :delete and @table[:table] == :done

    @db.disable_gc do # garbage collection problems
      rs = list()
      rep = generate_report( rs, :numbered => true ).tap{ puts self }
      if( !(rep.empty?) )
        require 'readline'
        recnos =
        if((max = rs.length) == 1)
          exit! unless Readline.readline("use this item?\n") =~ /^(?:(?:y|1)e?s?)?$/i
          rs[0].recno

        else
          Readline.readline(prompt).split( /(?:\s+)|,/ ).
          reject {|s| s.empty?}.map! do |n|
            if (m = n.match( /(\d+)(?:-|..)(\d+)/ ))
              Range.new(m[1].to_i, m[2].to_i).to_a
            else
              n.to_i
            end
          end.flatten.map! do |n|
            (puts "number out of range"; retry) if n == 0 or n > max
            rs[n - 1].recno
          end.tap{ (puts "no items modified"; exit!(0)) if empty? }
        end

        @db.send( mod_type, *recnos, &block )
      end
    end
  end

  # options are passed on to TodoList.new
  def self.session( type, prompt, options={}, &block )
    # all is not supported
    case type
    when :edit    then TodoList.new( options.merge(:all => false, :table => :todo) )
    when :restore then TodoList.new( options.merge(:all => false, :table => :done) )
    when :delete  then TodoList.new( options.merge(:all => false) )
    else fail
    end.session(type, prompt, &block)
  end

  def self.add
    db = Thread.new { connect_to_db }
    addition = parse_add_args()
    db.value.add addition
  end

  def self.parse_list_options
    options = {}

    if (arg=ARGV.first and arg[0,1] == '-')
      require 'optparse'
      begin
        OptionParser.new do |opts|
          opts.banner = "Usage: [mode options] Action [file options] [display options] [Action Options]"
          opts.separator "  mode options:"
          opts.on("-l", "--local", "do not run todo_server.rb in the background (slow)"){}#local_connection_arg?
          opts.on("-s", "--server", "start the server (unix only for now)"){}
          opts.separator ''
          opts.separator "  display options:"
          opts.on("-N", "--note", "display note text") { options[:note] = true }
          opts.on("-q", "--quiet", "don't display header")  { options[:quiet] = true }
          opts.on("-p", "--pdf", "output as todo.pdf") { options[:ruport] = :pdf }
          opts.on("-h", "--html", "output as todo.html") { options[:ruport] = :html }
          opts.separator ''
          opts.separator "  file options:"
          opts.on("-D", "--done", "use done tasks only") { options[:table] = :done }
          opts.on("-a", "--all", "use both todo and done tasks") { options[:all] = true }
        end.parse!

      rescue OptionParser::ParseError
        require 'rdoc/usage'; gets(); RDoc::usage('Actions');
      end
    end

    return options
  end
end

def parse_command_line_options( args=ARGV )
  case ($arg = args.shift)
  when /^--?lo?c?a?l?$/
    $local_connection = true
    return parse_command_line_options()

  when /^--?se?r?v?e?r?$/
    if start_todo_server()
      return parse_command_line_options()
    else
      puts '--server option not available on windows'
      exit!
    end

  when /^don?e?$/ # must be place above delete
    args.unshift('list', '--done' )
    return parse_command_line_options()

  when /^ta?g?s?$/
    help if args.empty?
    args.unshift('list', '-t' )
    return parse_command_line_options()

  when /^ad?d?$/
    TodoList.add

  when /^de?l?e?t?e?$/, /^rm$/
    TodoList.session( :delete, "\n enter numbers to delete\n" )

  when /^re?s?t?o?r?e?$/ # maybe call it undo?
    TodoList.session( :restore, "\n enter numbers to restore\n" )

  when /^li?s?t?$/
    puts TodoList.report

  when /^co?n?t?e?x?t?s?$/
    puts TodoList.seperate_reports( CONTEXT_START_MATCH )

  when /^pr?o?j?e?c?t?s?$/
    puts TodoList.seperate_reports( PROJECT_START_MATCH )

  when /^ed?i?t?$/
    first_entry = true
    TodoList.session( :edit, "\n enter numbers to replace/edit\n" ) do |record|
      puts "     press up to load entry text\n" if first_entry
      first_entry = false

      entry = record_to_input( record )
      print( "\n", entry, "\n" )
      Readline::HISTORY.push entry
      parse_add_args( Readline.readline.split(' ') )
    end

  when /^st?a?t?e?$/
    help if args.empty? # new state

    new_state = case (new_state = args.shift)

                when /^do?n?e?$/
                  args.unshift( 'delete' )
                  return parse_command_line_options()

                else state_match_to_string( new_state ) || help()
                end

    TodoList.session(:edit,
    "\n enter numbers to change their state to '#{new_state}'\n",
    :queries => {:state => (ACTION_STATES.dup.tap { delete(new_state) }) }
                    ) do |record|
      record.tap {|r| r[:state] = new_state }
    end

  # shortcut to displaying options with a certain state
  when /^:?(ne?x?t?)$/, /^:?(wa?i?t?)$/, /^:?(ma?y?b?e?)$/
    new_state = state_match_to_string( Regexp.last_match[1] ) || help()
    args.unshift( 'list', (':' << new_state) )
    return parse_command_line_options()

  else help()
  end
end

def state_match_to_string( state )
  case state
  when /^ne?x?t?$/   then 'next'
  when /^wa?i?t?$/   then 'wait'
  when /^ma?y?b?e?$/ then 'maybe'
  else nil
  end
end

main() if __FILE__ == $0
