# -*- coding: utf-8 -*-

require 'uri'
require 'nkf'
require 'haml'
require 'sass'
require 'tmpdir'
require 'sanitize'
require 'kramdown'
require 'mime-types'
require 'slack-notifier'
require 'sinatra/base'
require 'sinatra/reloader'
require 'sinatra/config_file'

require_relative 'git'
require_relative 'error'
require_relative 'kramdown_custom'

module RubWiki2
  class App < Sinatra::Base

    configure :development do
      register Sinatra::Reloader
      also_reload File.join(File.dirname(__FILE__), 'git.rb')
      also_reload File.join(File.dirname(__FILE__), 'error.rb')
      also_reload File.join(File.dirname(__FILE__), 'kramdown_custom.rb')
    end

    register Sinatra::ConfigFile
    config_file File.join(File.dirname(__FILE__), '../config/config.yml')

    set :public_folder, File.join(File.dirname(__FILE__), '../public')
    set :views, File.join(File.dirname(__FILE__), '../views')
    set :haml, :escape_html => true

    helpers do
      def guess_mime(path)
        begin
          content_type MIME::Types.type_for(path)[0].to_s
        rescue
          content_type 'text/plain'
        end
      end

      def remote_user
        request.env['REMOTE_USER'] || request.env['HTTP_X_FORWARDED_USER'] || 'anonymous'
      end

      def merge(web, old, new)
        merge = nil
        Dir.mktmpdir do |dir|
          Dir.chdir(dir) do
            File.write("web", web)
            File.write("old", old)
            File.write("new", new)
            IO.popen("diff3 -mE web old new", "r", :encoding => Encoding::UTF_8) do |io|
              merge = io.read
            end
          end
        end
        return merge, ($? == 0)
      end

      def error(errorcode, title, message = nil)
        content = haml(:error, locals: { title: "#{errorcode}: #{title}", message: message })
        content = haml(:border, locals: { content: content })
        halt(errorcode, haml(:default, locals: { content: content }))
      end

      def markdown(data)
        options = { git: @git, baseurl: url('/') }
        html = Kramdown::Document.new(data, options).to_html_custom
        return Sanitize.fragment(html, Sanitize::Config::RELAXED)
      end

      def notify(path, author, message, type:, revisions: nil)
        wikiname = settings.wikiname

        if settings.slack
          begin
            opts = {username: wikiname}.merge(settings.slack)
            notifier = Slack::Notifier.new settings.slack[:webhook], opts

            if revisions
              diff_url = url(URI.encode("#{path}?diff&from=#{revisions[:old]}&to=#{revisions[:new]}"))
              diff_link = "<#{diff_url}|(diff)>"
            end

            attachment = {
              title: "<#{url}|#{Slack::Notifier::Util::Escape.html path}> #{type} #{diff_link}",
              text: Slack::Notifier::Util::Escape.html(message),
              author_name: author,
            }

            notifier.post(attachments: [attachment])
          rescue
            # noop
          end
        end
      end
    end

    before do
      @git = Git.new(settings.git_repo_path)
    end

    get '/css/style.css' do
      scss(:style)
    end

    get '' do
      redirect to('/')
    end

    get '*/' do |path|
      path = path[1..-1] if path[0] == '/'
      case request.query_string
      when ''
        if @git.exist?(path)
          obj = @git.get(path)
          if obj.type == :tree
            entries = []
            obj.children.each do |name, obj|
              case obj.type
              when :blob
                entries << { name: File.basename(name, '.md'), type: :blob }
              when :tree
                entries << { name: name, type: :tree }
              end
            end
            content = haml(:dir, locals: { entries: entries, path: path })
            content = haml(:dirtab, locals: { content: content, activetab: :dir })
            return haml(:default, locals: { content: content })
          else
            error(400, "#{path} はディレクトリではありません")
          end
        else
          error(404, "#{path} というディレクトリは存在しません")
        end
      when 'history'
        if @git.exist?(path)
          unless @git.get(path).type == :tree
            error(400, "#{path} はファイルではなくディレクトリです")
          end
          log = @git.log(path)
          content = haml(:dirhistory, locals: { log: log, path: path })
          content = haml(:dirtab, locals: { content: content, activetab: :history })
          return haml(:default, locals: { content: content })
        else
          error(404, "#{path} は存在しません")
        end
      when 'new'
        content = haml(:new)
        content = haml(:border, locals: { content: content })
        return haml(:default, locals: { content: content })
      when /^diff&from=([0-9a-f]{40})&to=([0-9a-f]{40})$/
        roottrees = { from: @git.get_from_oid($1), to: @git.get_from_oid($2)}
        trees = {}
        roottrees.each do |key, tree|
          if tree.exist?(path)
            trees[key] = tree.get(path)
          else
            error(404, "Revision #{tree.oid} に #{path} は存在しません")
          end
        end
        diff = trees[:from].diff(trees[:to])
        content = haml(:dirdiff, locals: { diff: diff, title: path, trees: roottrees })
        content = haml(:dirtab, locals: { content: content, activetab: nil })
        return haml(:default, locals: { content: content })
      else
        error(400, "不正なクエリです")
      end
    end

    get '*' do |path|
      path = path[1..-1] if path[0] == '/'
      case request.query_string
      when ''
        if @git.exist?(path + '.md')
          # file (*.md)
          obj = @git.get(path + '.md')
          case obj.type
          when :blob
            content = markdown(obj.content)
            content = haml(:page, locals: { content: content, title: path })
            content = haml(:tab, locals: { content: content, activetab: :page })
            return haml(:default, locals: { content: content })
          when :tree
            error(500, "#{path}.md というディレクトリが存在します",
                  'Git レポジトリを直接操作して修正してください。')
          end
        elsif @git.exist?(path)
          obj = @git.get(path)
          case obj.type
          when :blob
            # file
            guess_mime(path)
            return obj.content
          when :tree
            # dir (redirect)
            redirect to(URI.encode(path) + '/')
          end
        else
          redirect to(URI.encode(path) + '?edit')
        end
      when 'edit'
        if @git.exist?(path) && @git.get(path).type == :blob
          error(400, "#{path} は Markdown 以外のファイルです")
        end
        obj = nil
        if @git.exist?(path + '.md')
          obj = @git.get(path + '.md')
          unless obj.type == :blob
            error(500, "#{path}.md というディレクトリが存在します",
                  'Git レポジトリを直接操作して修正してください。')
          end
        elsif !@git.can_create?(path + '.md')
          error(400, "#{path} は作成できません")
        end

        form = haml(:form, locals: {
                      markdown: obj ? obj.content : '', oid: obj ? obj.oid : '',
                      message: '', notify: true
                    })
        content = haml(:edit, locals: { form: form, title: path })
        content = haml(:tab, locals: { content: content, activetab: :edit })
        return haml(:default, locals: { content: content })
      when 'history'
        if @git.exist?(path + '.md')
          unless @git.get(path + '.md').type == :blob
            error(500, "#{path}.md というディレクトリが存在します",
                  'Git レポジトリを直接操作して修正してください。')
          end
          log = @git.log(path + '.md')
          content = haml(:history, locals: { log: log, path: path })
          content = haml(:tab, locals: { content: content, activetab: :history })
          return haml(:default, locals: { content: content })
        else
          if @git.exist?(path)
            error(400, "#{path} は Markdown 以外のファイルです")
          else
            error(404, "#{path} は存在しません")
          end
        end
      when 'raw'
        redirect to(URI.encode(path) + '.md')
      when /^revision=([0-9a-f]{40})$/
        tree = @git.get_from_oid($1)
        if tree.exist?(path + '.md')
          obj = tree.get(path + '.md')
          content = markdown(obj.content)
          content = haml(:revision, locals: { content: content, title: path, revision: $1 })
          content = haml(:tab, locals: { content: content, activetab: nil })
          return haml(:default, locals: { content: content })
        elsif tree.exist?(path)
          error(400, "#{path} は Markdown 以外のファイルです")
        else
          error(404, "#{path} は存在しません")
        end
      when /^diff&from=([0-9a-f]{40})&to=([0-9a-f]{40})$/
        trees = { from: @git.get_from_oid($1), to: @git.get_from_oid($2)}
        blobs = {}
        trees.each do |key, tree|
          if tree.exist?(path + '.md')
            blobs[key] = tree.get(path + '.md')
          elsif tree.exist?(path)
            error(400, "Revision #{tree.oid} の #{path} は Markdown 以外のファイルです")
          else
            error(404, "Revision #{tree.oid} に #{path} は存在しません")
          end
        end
        patch = blobs[:from].diff(blobs[:to])
        content = haml(:diff, locals: { patch: patch, title: path, trees: trees })
        content = haml(:tab, locals: { content: content, activetab: nil })
        return haml(:default, locals: { content: content })
      else
        error(400, "不正なクエリです")
      end
    end

    post '*' do |path|
      path = path[1..-1] if path[0] == '/'
      case request.query_string
      when 'preview'
        form = haml(:form, locals: {
                      markdown: params[:markdown], oid: params[:oid],
                      message: params[:message], notify: params[:notification] != 'false'
                    })
        content = markdown(params[:markdown])
        content = haml(:preview, locals: { form: form, content: content, title: path })
        content = haml(:tab, locals: { content: content, activetab: :edit })
        return haml(:default, locals: { content: content })
      when 'commit'
        raise Error::EmptyCommitMessage.new if params[:message].empty?()
        md_from_web = NKF.nkf('-Luw', params[:markdown])
        if @git.exist?(path + '.md')
          old_rev = @git.current_tree
          old_obj = @git.get(path + '.md')
          if old_obj.oid == params[:oid]
            @git.add(path + '.md', md_from_web)
            @git.commit(remote_user(), params[:message])

            if params[:notification] != 'false'
              notify(path, remote_user(), params[:message], type: :updated, revisions: {old: old_rev, new: @git.current_tree})
            end

            redirect to(URI.encode(path))
          else
            old_obj = @git.get_from_oid(params[:oid])
            new_obj = @git.get(path + '.md')
            merged, success = merge(md_from_web, old_obj.content, new_obj.content)
            if success
              @git.add(path + '.md', merged)
              @git.commit(remote_user(), params[:message])

              if params[:notification] != 'false'
                notify(path, remote_user(), params[:message], type: :updated, revisions: {old: old_rev, new: @git.current_tree})
              end

              redirect to(URI.encode(path))
            else
              form = haml(:form, locals: {
                            markdown: merged, oid: new_obj.oid,
                            message: params[:message], notify: params[:notification] != 'false'
                          })
              content = haml(:conflict, locals: { form: form, content: content, title: path })
              content = haml(:tab, locals: { content: content, activetab: :edit })
              return haml(:default, locals: { content: content })
            end
          end
        elsif @git.can_create?(path + '.md')
          @git.add(path + '.md', md_from_web)
          @git.commit(remote_user(), params[:message])

          if params[:notification] != 'false'
            notify(path, remote_user(), params[:message], type: :created)
          end

          redirect to(URI.encode(path))
        else
          error(400, "#{path} は作成できません")
        end
      when 'search'
        result = @git.search(params[:keyword])
        result = result.select do |entry|
          File.extname(entry) == '.md'
        end
        result = result.map do |entry|
          entry.sub(/.md$/, '')
        end
        content = haml(:search, locals: { result: result, keyword: params[:keyword] })
        content = haml(:border, locals: { content: content })
        return haml(:default, locals: { content: content })
      when 'new'
        redirect to(URI.encode(params[:path]) + '?edit')
      else
        error(400, "不正なクエリです")
      end
    end
  end
end
