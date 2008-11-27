#!/usr/bin/env ruby

# copyright Greg Weber
# license: GPL

#TODO
# distribution
# - gem?
# - include GPL notice
# default sorting? maybe by recno
# make constants configurable - yaml? - could add readline configuration too
#   variabalize help message
#   configurable fields? main problem is actually the changes to command line
#     new field will not be kb_nil for existing
# next action recommender
# colorization - context/project titles
# more testing - create mocks
# abstract this as a framework
#
# kirbybase patches
#   bug (fixed): add_column will append a '|' to empty lines
#   waiting on current patch
#   table#set, etc should not expose fpos and line_length
#   there are a lot of filter.include?, so could make a filter hash or struct
#   api
#     - select(:field => value)
#     - select, update, delete should be exactly the same
#   should use module Kirbybase factory to avoid meta programming
#   get rid of KBTableRec class and just modify the record class
#     - Lookup, LinkMany, and Calculated values will need to be created before assigned
#     - this will allow easy creation of an each iterator which willl allow for
#     removal of a lot of code, and new enumerable methods
#
# require ruport version with my patch (1.1)

WORKING_DIR = '~/todo'
SERVER_HOST = '127.0.0.1'
SERVER_PORT = 0
TODO_TBL = :todo
DONE_TBL = :done
DONE_STATE = 'done'
START_STATE = 'next'
ACL_LIST = %w[allow 127.0.0.1]# allow 192.168.1.*]
DELETE_FROM_DONE_DAYS = 30 #days items are kept on done list
FIELDS = [:item, :state, :tags, :due, :PRI, :note, :created, :modified]
FIELD_TYPES = Hash.new( :String )

begin
  %w[/home/greg/dev/kirbybase/kirbybase.rb].each {|lib| require lib}
rescue LoadError
  %w[rubygems kirbybase].each {|lib| require lib}
end
%w[parsedate enumerator drb drb/acl rinda/ring rinda/tuplespace].each {|lib| require lib}

def cd_wd
  begin
    Dir.chdir( File.expand_path( WORKING_DIR ) )
  rescue
    # use current directory
    puts "working directory:\n  #{WORKING_DIR}\ndoes not exist"
    fail
  end
end

def start_db
  cd_wd()

  $db = if(todo=ARGV[0])
          if(done=ARGV[1]) then TodoDB.new( todo, done )
          else TodoDB.new( todo )
          end
        else TodoDB.new()
        end
end

def main
  start_db()

  DRb.install_acl( ACL.new( ACL_LIST.flatten ) )
  $SAFE = 1
  DRb.start_service #"druby://#{SERVER_HOST}:#{SERVER_PORT}"
  start_ring_server(:name, :TodoDB, $db, 'todo list')
  puts "todo_server listening on #{DRb.uri}", "ACL:", ACL_LIST
  DRb.thread.join
end

def start_ring_server( *tupple_space_args )
  begin
    ts = Rinda::RingFinger.new.lookup_ring_any(5)
    puts "Located Ring server at #{ts.__drburi}"
  rescue RuntimeError
    puts "starting ring server"
    ts = Rinda::TupleSpace.new
    ring_server = Rinda::RingServer.new(ts)
  end

  begin
    ts.write( tupple_space_args, Rinda::SimpleRenewer.new )
  rescue Exception
    puts "could not register service with the ring server"
    exit(-1)
  end
end

############### HELPERS ####################
class Object
  def map_msg(meth, *args)
    map{|o| o.send(meth, *args)}
  end
  def tap( &block );
    block.arity == 1 ? block.call(self) : instance_eval(&block)
    return self
  end
end

module GarbageMan
  # fixes druby premature garbage collection problems
  def disable_gc
    GC.disable; yield
  ensure
    GC.enable
  end
end
####################################


module TodoResultSet
  # quiet = don't print header
  # numbered = number the items
  def to_s( options={} );
    if options[:numbered]
      rep_array = to_report(nil,false,*options[:filters]).split("\n")

      body_len = rep_array.size - 2
      spacing = body_len.to_s.size

      num_array = (1..body_len).to_a.map {|n| sprintf( "%#{spacing}d", n )}

      if options[:quiet] then ""
      else
        (' ' * spacing) << ' |  ' << rep_array[0].sub(' ', '') << "\n" <<
        ('-' * (spacing+2)) << rep_array[1] << "\n"

      end << rep_array[2..-1].enum_with_index.map do |bod,i|
               num_array[i] << ' | ' << bod
             end.join("\n")

    elsif options[:quiet]
      to_report(nil,false,*options[:filters]).split("\n")[2..-1].join("\n")

    else
      to_report(nil,false,*options[:filters]).
       sub('item       ', "#{sprintf("%5d", size)} items")
    end
  end

  # convert all records to arrays
  def to_arrays( *filters )
    if filters.empty? or filters == @filter
      if first.is_a? Struct # to_a will give correct order for Struct
        return map { |record| record.to_a }
      else
        filters = @filter
      end
    end

    map do |record|
      filters.map {|f| record.send(f) }
    end
  end

  def report_table( *filters )
    filters = @filter if filters.empty?
    {:data => to_arrays( *filters ), :column_names => filters.map{|sym| sym.to_s}}
  end
end


############# KIRBYBASE EXTENSIONS #################
    ###### my patched version! #####
class KBResultSet
    DELIM = ' | '
    NUMBER_FIELDS = [:Integer, :Float]
    JUSTIFY_HASH = { :String => :ljust, :Integer => :rjust,
     :Float => :rjust, :Boolean => :ljust, :Date => :ljust,
     :Time => :ljust, :DateTime => :ljust }
    #-----------------------------------------------------------------------
    # to_report
    #-----------------------------------------------------------------------
    def to_report(recs_per_page=nil, print_rec_sep=false, *filter)
        if !filter.first
          filter, filter_types = @filter, @filter_types
        else
          filter_types = filter.map do |f|
            @filter_types[@filter.index(f) || (fail "invalid filter: " << f.to_s)]
          end
        end

        result = collect { |r| filter.collect {|f| r.send(f)} }

        # columns of physical rows
        columns = [filter].concat(result).transpose

        max_widths = columns.collect { |c|
            c.max { |a,b| a.to_s.length <=> b.to_s.length }.to_s.length
        }

        row_dashes = '-' * (max_widths.inject {|sum, n| sum + n} +
         DELIM.length * (max_widths.size - 1))

        header_line = filter.zip(max_widths, filter.collect { |f|
            filter_types[filter.index(f)] }).collect { |x,y,z|
                 x.to_s.send(JUSTIFY_HASH[z], y) }.join(DELIM)

        output = header_line + "\n" << row_dashes + "\n"
        start = 0
        recs_per_page ||= result.length

        loop do
            page_of_results = result[start..(start + recs_per_page - 1)]
            break if page_of_results.empty?

            output << page_of_results.map do |row|
                row.zip(max_widths, filter.collect { |f|
                    filter_types[filter.index(f)] }).collect { |x,y,z|
                        x.to_s.send(JUSTIFY_HASH[z], y) }.join(DELIM) << "\n"
            end.join('')

            output << (row_dashes + "\n") if print_rec_sep
            output << "\f" unless start == 0
            start += recs_per_page
        end

        return output
    end

  include TodoResultSet
end
#######################################################


# abstract class for KirbyBase
class KirbyBaseDB
  def initialize( *args )
    @db = KirbyBase.new( *args )
  end

  def list( options={}, queries={}, *sort_fields )
    table = @tables[options[:table]] || (fail ArgumentError, "no valid table given")

    selectors = options[:selectors] || []
    selectors.push :recno unless selectors.include? :recno
    sort_fields[0] ||= :recno
    
    if queries.empty?
      table.select(*selectors)
    else
      table.select( *selectors ) do |record|
        queries.all? do |field, values|
          values.all? {|value| value =~ record.send(field).to_s }
        end end
    end.sort( *sort_fields )
  end

private
  def pack; @tables.map_msg( :pack ) end

  # modify table colunms if necessary
  def open_tables( *args )
    fail ArgumentError if args.empty?
    tables = []

    @tables = Struct.new( *
    args.enum_slice(2).map do |table_name, fields|
      tables.push(
        if @db.table_exists?( table_name )
          t = @db.get_table( table_name )
          old_fields = t.field_names
          new_fields = fields.enum_slice(2).map {|f,type| f}.push :recno
          new_fields.uniq!

          unless (old_fields.sort_by{|a| a.to_s} == new_fields.sort_by{|a| a.to_s})
            (new_fields - old_fields).each do |field|
              t.add_column( field, :String, nil )
            end
            dropped = (old_fields - new_fields)
            unless dropped.empty?
              FileUtils.cp t.filename, (t.filename + '.bak2')
              dropped.each do |field|
                t.drop_column( field )
              end
            end
          end
          t
        else
          @db.create_table( table_name, *fields )
        end )
      table_name
    end ).new( *tables )
  end

  def table_delete_recnos( table, *recnos )
    table.delete { |record| recnos.include?( record.recno ) }
  end

  def table_edit_recnos( table, *recnos )
    table.update {|r| recnos.include?( r.recno ) }.sort(:recno).set do |record|
      yield record
    end
  end

  def table_swap_recnos( start_table, end_table, *recnos, &block )
    case recnos.size
    when 0 then fail ArgumentError, "no recnos given"
    when 1 then [start_table[*recnos]]
    else start_table[*recnos]
    end.each do |record|
      table_add( end_table, record, &block )
    end

    table_delete_recnos( start_table, *recnos )
  end

  def table_add( table, *records, &block )
    record_modify( table, *records, &block ).each do |record|
      table.insert( record )
    end
  end

  def record_modify( table, *records, &block )
    if block
      records.map! {|record| record.tap {|r| block.call(r)} }
    else
      records
    end
  end
end

class TodoDB < KirbyBaseDB
  # do not let the user modify these when doing edits
  NO_EDIT_FIELDS = [:recno, :created, :modified]

  # note is too big, user does not care about created and modified
  DEFAULT_INVISIBLE_FIELDS = [:note, :created, :modified]

  include GarbageMan

  # methods using inheritance
  def initialize( todo_name=TODO_TBL, done_name=DONE_TBL )
    db_fields = FIELDS.map {|f| [f, FIELD_TYPES[f]]}.flatten
    super()
    open_tables( todo_name, db_fields, done_name, db_fields )
    start_maitenance_thread if __FILE__ == $0
  end

  # runs at startup and then every 24 hours
  def start_maitenance_thread
    day_seconds = 24 * 60 * 60

    maitenance_block = lambda do
      done_period = DELETE_FROM_DONE_DAYS * day_seconds
      old_recnos = []
      now = Time.now

      list( :selectors => [:recno, :created, :modified], :table => :done ).each do |record|
        t = Time.local( *ParseDate.parsedate( record.modified ) ) 
        old_recnos.push( record[:recno] ) if ( now - t ) > done_period
      end

      delete_from_done( *old_recnos ) unless old_recnos.empty?
    end

    maitenance_block.call
    pack() # get rid of blank lines and make things look nice

    @tables.each do |table|
      FileUtils.cp table.filename, (table.filename + '.bak')
    end

    # need a reference so thread is not garbage collected
    @maitenance_thread = Thread.new do
      loop do
        sleep day_seconds
        maitenance_block.call
        pack() # get rid of blank lines to speed up db
      end
    end
  end

  def list( options={}, queries={} )
    options[:table] ||= :todo
    options[:selectors] ||= table.field_names - DEFAULT_INVISIBLE_FIELDS
    super( options, queries )
  end

  # caller should update record same as adding a record
  # or can just use the yielded structure directly
  def edit( *recnos )
    table_edit_recnos( @tables[:todo], *recnos ) do |record|
      record.each_pair { |k,v| record[k] = nil if v == kb_nil }
      old_state = record[:state]

      yield( record ).each_pair do |k,v|
         next if NO_EDIT_FIELDS.include? k
         record[k] = v
      end

      record[:state] ||= old_state
      record[:modified] = nil # filled in by add_defaults
      add_defaults!( record )
    end
  end

  def add( *records );
    table_add( @tables[:todo], *records ) do |record|
      add_defaults!( record )
    end
  end

  def restore( *recnos )
    table_swap_recnos( @tables[:done], @tables[:todo], *recnos ) do |record|
      record[:state] = START_STATE
    end
  end

  def delete( *recnos )
    table_swap_recnos( @tables[:todo], @tables[:done], *recnos ) do |record|
      record[:state] = DONE_STATE
    end
  end

  def delete_from_done( *recnos )
    table_delete_recnos( @tables[:done], *recnos )
  end

private
  def add_defaults!( new_entry )
    time = Time.now.to_s
    new_entry[:created]  ||= time
    new_entry[:modified] ||= time
    new_entry[:state]    ||= START_STATE
  end
end

main() if __FILE__ == $0

=begin no longer used code
class KBResultSet
  # this is used after performing an inplace modification like map!
  # if the structure members must equal the filter variable
  def update_filters
    filter = self.find{|a| a}
    return false unless filter
    filter = filter.members.map_msg(:to_sym)

    if filter != @filter
      @filter = filter
      name_to_type = @table.field_names_and_types << [:recno, :Integer]

      @filter_types = @filter.map{|f| name_to_type.each do |a|
          break a[1] if f == a[0]
        end
      }
      true
    else
      false
    end
  end
end

module ResetRecnos
  # modifies db in unsynchronized way, so only run at startup,
  # it is not necessary, but makes file nicer looking by resetting recnos
  # and removing blank lines (which could be accomplished by pack)
  def reset_recnos!
    FileUtils.cp @filename, 'temp.tbl'
    @db.get_table( :temp ).copy_to( self )
    @db.drop_table :temp
  end

  def copy_to( dest_table, *sort_fields )
    dest_table.clear
    select().sort(:recno).each {|r| dest_table.insert( r ) }
  end
end
begin # my patched version
  module KBTable; class KBTable; include ResetRecnos end end
rescue TypeError
  class KBTable; include ResetRecnos end
end
=end
