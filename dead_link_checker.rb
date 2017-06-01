require 'net/http'
require 'openssl'
require 'time'

start_time = Time.now

# 再帰対象から除外するURLの正規表現
$IGNORE_PATTERNS = [/\.pdf(\?.*)?$/i]
$MESSAGE_LENGTH = 100
OPTS_ABB = {o: :once, l: :local}

@options = []
ARGV.delete_if{ |arg|
  case arg
  when /^--([\w]+)/
    @options.push($1.to_sym)
    true
  when /^-([\w]+)/
    @options.concat($1.split('').map{|c| OPTS_ABB[c.to_sym] })
    true
  else
    false
  end
}

@root_url_str = ARGV[0]
@root_uri = URI.parse(@root_url_str)
@root_uri.path = '/' if @root_uri.path.empty?

@root_http = Net::HTTP.new(@root_uri.host, @root_uri.port)
@root_http.open_timeout = 5
if @root_uri.kind_of?(URI::HTTPS)
  @root_http.use_ssl = true
  @root_http.verify_mode = OpenSSL::SSL::VERIFY_NONE # なんかSSL証明書エラーが出るんで検証しない
end

@yomikae_host = ARGV[1]
@root_length = nil

@stack = [[@root_url_str, true, '.', -1]]
@results = []
@log_loc = []
@log_glb = []

# URLの変換
def analyze_url(url_str)
  begin
    uri = URI.parse(url_str)
    path = uri.path
    is_local = (uri.host == @root_uri.host) || (uri.host == @yomikae_host)
    if is_local
      http = @root_http
    else
      http=Net::HTTP.new(uri.host, uri.port)
      http.open_timeout = 5
      if uri.kind_of?(URI::HTTPS)
        http.use_ssl = true
        http.verify_mode = OpenSSL::SSL::VERIFY_NONE # なんかSSL証明書エラーが出るんで検証しない
      end
    end
  rescue Exception => e
    raise e
  end
  if path.nil? || path.empty?
    path = '/'
  end
  return [http, path, is_local]
end

# 訪問済みかどうかのチェック
def check_log(is_loc, path)
  if is_loc
    if @log_loc.include?(path)
      return true
    else
      @log_loc.push(path)
    end
  else
    if @log_glb.include?(path)
      return true
    else
      @log_glb.push(path)
    end
  end
  return false
end

def print_message(path, line, url, message='')
  page_status = path + ':' + line.to_s + ' ' + url
  len = $MESSAGE_LENGTH - message.length
  if page_status.length <= len
    stat_message = page_status + (' ' * (len - page_status.length))
  else
    stat_message = page_status[0...(len-3)] + '...'
  end
  print("\r" + stat_message + message)
end

# ページの存在を確認し、存在しない場合結果を表示するメソッド
# ローカルの場合は再帰的探索も行う
until @stack.empty?
  url_str, recursion, from_path, line_num = @stack.pop

  # 進捗の表示
  print_message(from_path, line_num, url_str)
  if from_path == @root_uri.path
    print('(' + (100 * line_num / @root_length).to_i.to_s + '%)')
  end

  # URLを解析する 相対パスも考慮
  if url_str.match(/^http/)
    begin
      http, path, is_local = analyze_url(url_str)
    rescue Exception => e
      @results.push({
        path: from_path,
        line: line_num,
        message: 'unknown error',
        url: url_str
      })
      #raise e
      next
    end
  else
    http = @root_http
    path = URI.join(@root_uri.to_s, from_path, url_str).path
    is_local = true
  end

  # ローカルモード用
  next if @options.include?(:local) && !is_local
  # 探索済だったら飛ばす
  next if (from_path != '.') && check_log(is_local, is_local ? path : url_str)

  # アクセス出来るかどうか
  begin
    print_message(from_path, line_num, url_str, '[conneting]')
    response = http.head(path)
  rescue Exception => e
    @results.push({
      path: from_path,
      line: line_num,
      message: 'connection error',
      url: url_str
    })
    next
  end
  location = nil
  cnt = 0
  # リダイレクト
  while response.is_a?(Net::HTTPRedirection)
    cnt += 1
    print_message(from_path, line_num, url_str, '[redirecting' + cnt.to_s + '/10]')
    if cnt >= 10
      # リダイレクトループしすぎだぞ
      @results.push({
        path: from_path,
        line: line_num,
        message: 'too redirect',
        url: url_str
      })
      break
    end
    http, path, is_local = analyze_url(response['location'])
    # リダイレクト先にアクセス出来るかどうか
    begin
      response = http.head(path)
    rescue Exception => e
      @results.push({
        path: from_path,
        line: line_num,
        message: 'connection error',
        url: url_str
      })
      break
    end
  end
  unless response.is_a?(Net::HTTPSuccess)
    # リダイレクト中のコネクションエラーを除外
    unless response.is_a?(Net::HTTPRedirection)
      # リンク切れだぞ
      @results.push({
        path: from_path,
        line: line_num,
        message: response.code,
        url: url_str
      })
    end
    next
  end
  # 成功だぞ
  #puts "#{from_path}:#{line_num}(#{response.code}) #{url_str}"

  # 再帰的チェック
  if is_local && recursion
    line_num = 0
    # 中身を読み込む
    print_message(from_path, line_num, url_str, '[loading body]')
    response = http.get(path)
    # 今ルートだったら行数を記録
    if @root_length.nil?
      @root_length = response.body.count("\n")
    end
    children = []
    body_text = response.body
    line_num = 0
    while /\A((?:(?:[^<]|(?:<(?!!--)))*<!--(?:[^-]|(?:-(?!->)))*-->)*?(?:[^<]|(?:<(?!!--)))*?)((?:<a [^>]*href)|(?:<img [^>]*src)) *= *['"]?((?:https?:\/\/)?[\w\/%#\$&\?\(\)~\.=\+\-]+(?:[\?#][\w\/:%#\$&\?\(\)~\.=\+\-]+)?)/.match(body_text)
      m = $~
      line_num += m[1].count("\n")
      tag = m[2]
      url = m[3]
      child_recursion = /^<a/.match(tag) && !(@options.include?(:once) || $IGNORE_PATTERNS.inject(false){|r, p| r || p.match(url) })
      children.unshift([url, child_recursion, path, line_num])
      body_text = m.post_match
    end
    @stack += children
  end
end

# 整形して結果の表示
message = 'Completed!'
print("\r" + message + (' ' * ($MESSAGE_LENGTH + 6 - message.length)) + "\n")
@results.sort { |a, b|
  a[:path] == b[:path] ? a[:line] <=> b[:line]
                       : a[:path] <=> b[:path] }
@results.each { |r|
  puts "#{r[:path]}:#{r[:line]}(#{r[:message]}) #{r[:url]}"
}

puts 'exec time: ' + (Time.now - start_time).to_i.to_s + 's'

File.open('result(' + @root_uri.host.gsub('.', '_') + ').txt', "w") do |file|
  @results.each { |r|
    file.puts("#{r[:path]}:#{r[:line]}(#{r[:message]}) #{r[:url]}")
  }
end
