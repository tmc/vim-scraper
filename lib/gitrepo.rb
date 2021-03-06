require 'gitrb'
require 'retryable'

# helps working with git repos, insulates app from underlying implementation
class GitRepo
  include Retryable

  # common failures should be GitErrors
  class GitError < RuntimeError; end
  attr_reader :root, :bare

  # required: :root, the directory to contain the repo
  # optional: :clone a repo to clone (:bare => true if it should be bare)
  #           :create to create a new empty repo if it doesn't already exist
  def initialize opts
    @root = opts[:root]
    @bare = opts[:bare]

    retryable_options opts[:retryable_options] if opts[:retryable_options]

    if opts[:clone]
      retryable(task: "cloning #{opts[:clone]}") do
        args = [opts[:clone], opts[:root]]
        args.push '--bare' if opts[:bare]
        git_exec :clone, *args
      end
    elsif opts[:create]
      Dir.mkdir opts[:root] unless File.directory? opts[:root]
      if opts[:bare]
        git :init, '--bare'
      else
        git :init
      end
    end

    # a little sanity checking, catch simple errors early
    raise GitError, "#{@root} does not exist" unless File.directory? @root
    if opts[:bare]
      unless File.directory? File.join(@root, 'objects')
        raise GitError, "#{@root} does not appear to be a bare repo"
      end
    else
      unless File.directory? File.join(@root, '.git')
        raise GitError, "#{@root}/.git does not exist"
      end
      unless File.directory? File.join(@root, '.git', 'objects')
        raise GitError, "#{@root}/.git does not appear to be a git repo"
      end
    end
  end

  def git_exec *args
    options = { before_exec: -> {} }
    options.merge! args.pop if args[-1].is_a? Hash
    args = args.map(&:to_s)

    out = IO.popen('-', 'r') do |io|
      if io    # parent
        block_given? ? yield(io) : io.read
      else     # child
        STDERR.reopen STDOUT
        options[:before_exec].call
        exec 'git', *args
      end
    end

    if $?.exitstatus > 0
      raise GitError, "git #{args.join(' ')}: #{out}"
    end

    out
  end

  def git *args
    Dir.chdir(@root) do
      git_exec(*args)
    end
  end

  def remote_add name, remote
    git :remote, :add, name, remote
  end

  def remote_remove name
    git :remote, :rm, name
  end

  def pull *args
    # Can we tell the difference between a network error, which we want to retry,
    # and a merge error, which we want to fail immediately?
    retryable(task: "pulling #{args.join ' '}") do
      git :pull, '--no-rebase', *args
    end
  end

  def push *args
    # like pull, can we tell the difference between a network error and local error?
    retryable(task: "pushing #{args.join ' '}") do
      git :push, *args
    end
  end

  def create_tag name, message, committer
    # gitrb doesn't handle annotated tags so we call git directly
    git :tag, '-a', name, '-m', message, before_exec: lambda {
      ENV['GIT_COMMITTER_NAME'] = committer[:name]
      ENV['GIT_COMMITTER_EMAIL'] = committer[:email]
      ENV['GIT_COMMITTER_DATE'] = (committer[:date] || Time.now).strftime('%s %z')
    }
  end

  def find_tag tagname
    tag = git :tag, '-l', tagname
    !tag || tag =~ /^\s*$/ ? nil : tag.chomp
  end

  # all the things you can do while committing
  class CommitHelper
    def initialize repo
      @repo = repo
    end

    # this empties out the commit tree so you can start fresh
    def empty_index
      entries.each { |name| remove name }
    end

    def remove name
      @repo.root.delete(name).dump
    end

    def add name, contents
      # an empty file is represented by the empty string so contents==nil is an error
      raise GitError, "no data in #{name}: #{contents.inspect}" unless contents
      @repo.root[name] = Gitrb::Blob.new(data: contents)
    end

    def entries
      @repo.root.to_a.map { |name, _| name }
    end

    # If the entry is a tree, returns an array of the names in the tree.
    # If a blob, returns the blob data.  Othewise returns nil.
    def entry name, type=nil
      data = @repo.root[name]
      raise GitError, "type was #{data.type} not #{type}" if type && type != data.type
      return data.map { |n, _| n } if data && data.type == :tree
      return data.dump if data && data.type == :blob
    end
  end

  def commit message, author, committer=author
    now = Time.now
    author = Gitrb::User.new(author[:name], author[:email], author[:date] || now)
    committer = Gitrb::User.new(committer[:name], committer[:email], committer[:date] || now)
    # gitrb has a bug where it will complain about frozen strings unless you dup the path
    repo = Gitrb::Repository.new(path: root.dup, bare: bare, create: false)
    repo.transaction(message, author, committer) do
      yield CommitHelper.new(repo)
    end
  end
end
