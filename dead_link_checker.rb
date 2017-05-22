require "net/http"
require "openssl"

$URL_PATTERN = '(?!mailto:)(?:https?:\/\/)?[\w\/:%#\$&\?\(\)~\.=\+\-]+'

@root_url_str = ARGV[0]
@root_uri = URI.parse(@root_url_str)
@root_http = Net::HTTP.new(@root_uri.host, @root_uri.port)
@root_http.use_ssl = @root_uri.kind_of?(URI::HTTPS)
@yomikae_host = ARGV[1]

@log_loc = []
@log_glb = []

# URLの変換
def analyze_url(url_str)
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
def check_page(url_str, recursion=true, from_path='/', line_num=-1)
  # URLを解析する 相対パスも考慮
  if url_str.match(/^http/)
    http, path, is_local = analyze_url(url_str)
  else
    http = @root_http
    path = URI.join(@root_uri.to_s, from_path, url_str).path
    is_local = true
  end

  # 探索済だったら帰る
  return nil if check_log(is_local, is_local ? path : url_str)

  # アクセス出来るかどうか
  response = http.get(path)
  location = nil
  cnt = 0
  # リダイレクト
  while response.is_a?(Net::HTTPRedirection)
    cnt += 1
    if cnt > 10
      # リダイレクトループしすぎだぞ
      puts "#{from_path}:#{line_num}(too redirect) #{url_str}"
    end
    http, path, is_local = analyze_url(response['location'])
    return nil if check_log(is_local, is_local ? path : url_str)
    response = http.get(path)
  end
  unless response.is_a?(Net::HTTPSuccess)
    # リンク切れだぞ
    puts "#{from_path}:#{line_num}(#{response.code}) #{url_str}"
    return response
  end
  # 成功だぞ
  #puts "#{from_path}:#{line_num}(#{response.code}) #{url_str}"

  # 再帰的チェック
  if is_local && recursion
    line_num = 0
    response.body.each_line.with_index do |line, line_num|
      # 画像を見つける（再帰チェックはしない）
      line.scan(/<img [^>]*src *= *['"]?(#{$URL_PATTERN})/i) do |match|
        check_page(match[0], false, path, line_num)
      end
      # リンクを見つける（再帰チェックするかも）
      line.scan(/<a [^>]*href *= *['"]?(#{$URL_PATTERN})/i) do |match|
        check_page(match[0], true, path, line_num)
      end
    end
  end

  return response
end

check_page(@root_url_str)
