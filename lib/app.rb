# -*- coding: utf-8 -*-

require 'uri'
require 'nkf'
require 'haml'
require 'sass'
require 'tmpdir'
require 'sanitize'
require 'kramdown'
require 'mime-types'
require 'sinatra/base'
require 'sinatra/reloader'
require 'sinatra/config_file'

require_relative 'git'
require_relative 'error'

module RubWiki2
  class App < Sinatra::Base

    configure :development do
      register Sinatra::Reloader
      also_reload File.join(File.dirname(__FILE__), 'git.rb')
      also_reload File.join(File.dirname(__FILE__), 'error.rb')
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

      def sanitize(html)
        return Sanitize.fragment(html, Sanitize::Config::RELAXED)
      end

      def remote_user
        if request.env['REMOTE_USER']
          return request.env['REMOTE_USER']
        else
          return 'anonymous'
        end
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
    end

    before do
      @git = Git.new(settings.git_repo_path)
    end

    get '/css/style.css' do
      scss(:style)
    end

    get '*/' do |path|
      path = path[1..-1] if path[0] == '/'
      obj = @git.get(path)
      entries = []
      obj.children.each do |name, obj|
        case obj.type
        when :blob
          entries << { name: File.basename(name, '.md'), type: :blob }
        when :tree
          entries << { name: name, type: :tree }
        end
      end
      content = haml(:dir, locals: { entries: entries })
      return haml(:default, locals: { content: content })
    end

    get '*' do |path|
      path = path[1..-1] if path[0] == '/'
      case request.query_string
      when ''
        if @git.exist?(path + '.md')
          # file (*.md)
          obj = @git.get(path + '.md')
          content = sanitize(markdown(obj.content))
          content = haml(:page, locals: { content: content, title: path })
          content = haml(:tab, locals: { content: content, activetab: :page })
          return haml(:default, locals: { content: content })
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
          raise Error::InvalidPath.new
        end
      when 'edit'
        obj = if @git.exist?(path + '.md')
                @git.get(path + '.md')
              elsif @git.can_create?(path + '.md')
                nil
              else
                raise Error::InvalidPath.new
              end
        form = haml(:form, locals: {
                      markdown: obj ? obj.content : '', oid: obj ? obj.oid : '',
                      message: '', notify: true
                    })
        content = haml(:edit, locals: { form: form, title: path })
        content = haml(:tab, locals: { content: content, activetab: :edit })
        return haml(:default, locals: { content: content })
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
        content = sanitize(markdown(params[:markdown]))
        content = haml(:preview, locals: { form: form, content: content, title: path })
        content = haml(:tab, locals: { content: content, activetab: :edit })
        return haml(:default, locals: { content: content })
      when 'commit'
        raise Error::EmptyCommitMessage.new if params[:message].empty?()
        md_from_web = NKF.nkf('-Luw', params[:markdown])
        if @git.exist?(path + '.md')
          old_obj = @git.get(path + '.md')
          if old_obj.oid == params[:oid]
            @git.add(path + '.md', md_from_web)
            @git.commit(remote_user(), params[:message])
            redirect to(URI.encode(path))
          else
            old_obj = @git.get_from_oid(params[:oid])
            new_obj = @git.get(path + '.md')
            merged, success = merge(md_from_web, old_obj.content, new_obj.content)
            if success
              @git.add(path + '.md', merged)
              @git.commit(remote_user(), params[:message])
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
          redirect to(URI.encode(path))
        else
          raise Error::InvalidPath.new
        end
      end
    end
  end
end
