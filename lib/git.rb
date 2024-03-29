require 'rugged'

require_relative 'error'

module RubWiki2
  class Git
    def self.chmod(repo, oid)
      path = "#{repo.path}objects/#{oid[0, 2]}"
      if File.stat(path).uid == Process::Sys.geteuid
        File.chmod(02775, path)
      end
    end

    def initialize(path)
      @repo = Rugged::Repository.new(path)
      @tree = Tree.get_trees(@repo)
    end

    def current_tree
      @repo.head.target.tree.oid
    end

    def add(path, data)
      @tree.add(path, data)
    end

    def rm(path)
      @tree.rm(path)
    end

    def log(path = nil)
      commits = []
      @repo.walk(@repo.head.target.oid) do |commit|
        if path == nil || commit.diff(paths: [path]).size > 0
          commits << commit
        end
      end
      return commits
    end

    def commit(kmc_id = 'anonymous', message = '')
      author = { email: "#{kmc_id}@kmc.gr.jp", name: kmc_id, time: Time.now }
      options = {
        tree: @tree.oid, author: author, committer: author, message: message,
        parents: @repo.empty? ? [] : [ @repo.head.target ].compact,
        update_ref: 'HEAD'
      }
      oid = Rugged::Commit.create(@repo, options)
      Git.chmod(@repo, oid)
    end

    def get(path)
      return @tree.get(path)
    end

    def exist?(path)
      if path.empty?
        return true
      else
        return @tree.exist?(path)
      end
    end

    def can_create?(path)
      return @tree.can_create_blob?(path)
    end

    def get_from_oid(oid)
      obj = @repo.lookup(oid)
      case obj.type
      when :blob
        return Blob.new(@repo, oid, Blob::UnknownMode)
      when :tree
        return Tree.get_trees(@repo, oid)
      end
    end

    def search(text)
      result = []
      @repo.head.target.tree.walk_blobs do |root, entry|
        # Ignore case
        text_down = text.downcase
        full_path = root + entry[:name]
        if full_path.downcase.include?(text_down)
          result << full_path
        else
          markdown = get_from_oid(entry[:oid]).content.scrub
          result << full_path if markdown.downcase.include?(text_down)
        end
      end
      return result
    end

    def search_file(basename)
      @repo.head.target.tree.walk_blobs do |root, entry|
        if File.basename(entry[:name], '.md') == basename
          return "/#{root}#{File.basename(entry[:name], '.md')}"
        end
      end
      return ''
    end
  end

  class Blob
    NormalFileMode = 0100644
    DirectoryMode = 0040000
    SymlinkMode = 0120000
    UnknownMode = nil

    def self.create(repo, data)
      oid = repo.write(data, :blob)
      Git.chmod(repo, oid)
      return Blob.new(repo, oid, NormalFileMode)
    end

    def initialize(repo, oid, filemode)
      @repo = repo
      @oid = oid
      @filemode = filemode
    end

    attr_reader :oid, :filemode

    def type
      return :blob
    end

    def get(path = '')
      if path.empty?
        return self
      else
        raise Error::InvalidPath.new("Blob can't contain \"#{path}\"")
      end
    end

    def content
      return @repo.lookup(@oid).text.force_encoding(Encoding::UTF_8)
    end

    def diff(blob)
      return @repo.lookup(@oid).diff(@repo.lookup(blob.oid))
    end

    def symlink?
      raise Error::UnknownMode.new if @filemode == UnknownMode
      @filemode == SymlinkMode
    end
  end

  class Tree
    # children: { name1 => obj1, name2 => obj2, ... }
    def self.create(repo, children)
      oid = self.create_tree_object(repo, children)
      return Tree.new(repo, oid, children)
    end

    def self.create_tree_object(repo, children)
      builder = Rugged::Tree::Builder.new(repo)
      children.each do |name, obj|
        case obj.type
        when :blob
          builder.insert({ type: obj.type, name: name, oid: obj.oid, filemode: obj.filemode })
        when :tree
          builder.insert({ type: obj.type, name: name, oid: obj.oid, filemode: Blob::DirectoryMode })
        end
      end
      oid = builder.write
      Git.chmod(repo, oid)
      return oid
    end

    def self.get_trees(repo, oid = nil)
      oid ||= repo.head.target.tree.oid
      children = {}
      repo.lookup(oid).each do |obj|
        case obj[:type]
        when :blob
          children[obj[:name]] = Blob.new(repo, obj[:oid], obj[:filemode])
        when :tree
          children[obj[:name]] = Tree.get_trees(repo, obj[:oid])
        end
      end
      return Tree.new(repo, oid, children)
    end

    def initialize(repo, oid, children)
      @repo = repo
      @oid = oid
      @children = children
    end

    attr_reader :oid, :children

    def type
      return :tree
    end

    def add(path, data)
      if path.include?('/')
        if @children.include?(path.partition('/').first)
          @children[path.partition('/').first].add(path.partition('/').last, data)
        else
          obj = Blob.create(@repo, data)
          path.split('/')[1..-1].reverse.each do |name|
            obj = Tree.create(@repo, { name => obj })
          end
          @children[path.split('/').first] = obj
        end
      else
        blob = Blob.create(@repo, data)
        @children[path] = blob
      end
      @oid = Tree.create_tree_object(@repo, @children)
    end

    def rm(path)
      if path.include?('/')
        @children[path.partition('/').first].rm(path.partition('/').last)
        if @children[path.partition('/').first].children.empty?
          @children.delete(path.partition('/').first)
        end
      else
        @children.delete(path)
      end
      @oid = Tree.create_tree_object(@repo, @children) unless @children.empty?
    end

    def get(path)
      if path.empty?
        return self
      else
        if @children.include?(path.partition('/').first)
          return @children[path.partition('/').first].get(path.partition('/').last)
        else
          raise Error::FileNotFound.new("Tree does not contain \"#{path.partition('/').first}\"")
        end
      end
    end

    def exist?(path)
      if path.include?('/')
        if @children.include?(path.partition('/').first)
          child = @children[path.partition('/').first]
          if child.type == :tree
            return child.exist?(path.partition('/').last)
          else
            return false
          end
        else
          return false
        end
      elsif path.empty?
        return true
      else
        return @children.include?(path)
      end
    end

    def can_create_blob?(path)
      if path.include?('/')
        if @children.include?(path.partition('/').first)
          child = @children[path.partition('/').first]
          if child.type == :tree
            return child.can_create_blob?(path.partition('/').last)
          else
            return false
          end
        else
          return true
        end
      else
        return !@children.include?(path)
      end
    end

    def diff(tree)
      return @repo.lookup(@oid).diff(@repo.lookup(tree.oid))
    end
  end
end
