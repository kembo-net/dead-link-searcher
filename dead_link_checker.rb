require "net/http"
require "openssl"

$URL_PATTERN = '(?!mailto:)(?:https?:\/\/)?[\w\/:%#\$&\?\(\)~\.=\+\-]+'
ONCE_COMMAND = '--once'

@once_mode = ARGV.include?(ONCE_COMMAND)
ARGV.delete(ONCE_COMMAND)

@root_url_str = ARGV[0]
@root_uri = URI.parse(@root_url_str)
@root_http=Net::HTTP.new(@root_uri.host, @root_uri.port)
if @root_uri.kind_of?(URI::HTTPS)
  @root_http.use_ssl = true
  @root_http.verify_mode = OpenSSL::SSL::VERIFY_NONE # なんかSSL証明書エラーが出るんで検証しない
end
@yomikae_host = ARGV[1]

@stack = [[@root_url_str, true, '/', -1]]
@results = []
@log_loc = []
@log_glb = []

# URLの変換
def analyze_url(url_str)
  begin
    uri = URI.parse(url_str)
    path = uri.path
    is_local = (uri.host == @root_uri.host) or (uri.host == @yomikae_host)
    if is_local
      http = @root_http
    else
      http=Net::HTTP.new(uri.host, uri.port)
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

# ページの存在を確認し、存在しない場合結果を表示するメソッド
# ローカルの場合は再帰的探索も行う
until @stack.empty?
  url_str, recursion, from_path, line_num = @stack.shift

  # 進捗の表示
  stat_message = from_path + ":#{line_num} " + url_str
  if stat_message.length <= 100
    stat_message = stat_message + (' ' * (100 - stat_message.length))
  else
    stat_message = stat_message[0..97] + '...'
  end
  print("\r" + stat_message)

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
      next
    end
  else
    http = @root_http
    path = URI.join(@root_uri.to_s, from_path, url_str).path
    is_local = true
  end

  # 探索済だったら飛ばす
  next if check_log(is_local, is_local ? path : url_str)

  # アクセス出来るかどうか
  begin
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
    if cnt > 10
      # リダイレクトループしすぎだぞ
      @results.push({
        path: from_path,
        line: line_num,
        message: 'too redirect',
        url: url_str
      })
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
    response = http.get(path)
    response.body.each_line.with_index do |line, line_num|
      # 画像を見つける（再帰チェックはしない）
      line.scan(/<img [^>]*src *= *['"]?(#{$URL_PATTERN})/i) do |match|
        @stack.push([match[0], false, path, line_num])
      end
      # リンクを見つける（再帰チェックするかも）
      line.scan(/<a [^>]*href *= *['"]?(#{$URL_PATTERN})/i) do |match|
        @stack.push([match[0], !@once_mode, path, line_num])
      end
    end
  end
end

# 整形して結果の表示
message = 'Completed!'
print("\r" + message + (' ' * (100 - message.length)) + "\n")
@results.sort { |a, b|
  a[:path] == b[:path] ? a[:line] <=> b[:line]
                       : a[:path] <=> b[:path] }
@results.each { |r|
  puts "#{r[:path]}:#{r[:line]}(#{r[:message]}) #{r[:url]}"
}