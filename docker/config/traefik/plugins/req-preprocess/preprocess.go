package req_preprocess

import (
	"context"
	"crypto"
	"crypto/rsa"
	"crypto/sha256"
	"crypto/x509"
	"encoding/base64"
	"encoding/json"
	"encoding/pem"
	"fmt"
	"io"
	"math"
	"math/rand"
	"net/http"
	"strconv"
	"strings"
	"time"
)

type Config struct {
	AuthUrl string // 认证服务url
	Key     string // JWT公钥
	Mark    string // 标志前缀
}

func CreateConfig() *Config {
	return &Config{
		AuthUrl: "",
		Key:     "",
		Mark:    "",
	}
}

type Preprocess struct {
	next      http.Handler
	name      string
	url       string
	publicKey *rsa.PublicKey
	mark      string
}

// JWT JWT对象格式
type JWT struct {
	header    string
	payload   string
	signature string
}

func New(ctx context.Context, next http.Handler, config *Config, name string) (http.Handler, error) {
	var publicKey *rsa.PublicKey = nil
	if config.Key != "" {
		publicKey = loadPublicKey(config.Key) // 加载pem公钥
	}
	return &Preprocess{
		next:      next,
		name:      name,
		url:       config.AuthUrl,
		publicKey: publicKey,
		mark:      config.Mark,
	}, nil
}

func (p *Preprocess) ServeHTTP(rw http.ResponseWriter, req *http.Request) {
	if p.mark != "" && p.redirect(req, rw) {
		return
	}
	if p.url != "" || p.publicKey != nil {
		// 删除可能存在的payload头
		req.Header.Del("payload")
	}
	if p.url != "" {
		// 对会话进行转发认证
		p.forwardAuth(req)
	} else if p.publicKey != nil {
		// 对携带JWT凭证的请求进行解析
		p.parseJWT(req)
	}
	p.addTraceId(req, rw) // 对请求添加traceId
	p.next.ServeHTTP(rw, req)
}

/*
将会话id转发给认证接口，用于检索会话信息传递给后面的业务接口
会话id保留在cookie中的sid字段中
*/
func (p *Preprocess) forwardAuth(req *http.Request) {
	sid, err := req.Cookie("sid")
	if err != nil {
		return
	}
	fReq, err := http.NewRequest("GET", p.url, nil)
	if err != nil {
		return
	}
	fReq.AddCookie(sid) // 携带会话id
	res, err := http.DefaultClient.Do(fReq)
	if err != nil {
		return
	}
	defer func(Body io.ReadCloser) {
		err = Body.Close()
		if err != nil {
			return
		}
	}(res.Body)
	// 读取响应体
	result, err := io.ReadAll(res.Body)
	if res.StatusCode != 200 || err != nil {
		return
	}
	req.Header.Add("Payload", string(result))
}

// ----- JWT相关 -----

func (p *Preprocess) parseJWT(req *http.Request) {
	authorization := req.Header.Get("Authorization")
	if authorization != "" {
		// 1. 将token解析为JWT格式
		jwt := splitToken("Bearer", authorization)
		if jwt.header == "" {
			return
		}
		// 2. 验证jwt凭证是否有效
		if ok := verifyJWT(jwt, p.publicKey); !ok {
			return
		}
		payload, err := base64.RawURLEncoding.DecodeString(jwt.payload)
		if err != nil {
			return
		}
		// 3. 验证jwt凭证是否过期
		var v map[string]interface{}
		if err = json.Unmarshal(payload, &v); err != nil || v["exp"] == nil {
			return
		}
		exp := int64(math.Floor(v["exp"].(float64)))
		if verifyExpires(exp) {
			return
		}
		req.Header.Add("Payload", string(payload))
	}
}

// 加载pem格式公钥
func loadPublicKey(key string) *rsa.PublicKey {
	block, _ := pem.Decode([]byte(key))
	parsedKey, _ := x509.ParsePKIXPublicKey(block.Bytes)
	rsaPublicKey := parsedKey.(*rsa.PublicKey)
	return rsaPublicKey
}

// 用于解析token为JWT数据格式
func splitToken(prefix string, authorization string) JWT {
	token := strings.TrimSpace(strings.TrimPrefix(authorization, prefix)) // remove prefix Bearer
	pToken := strings.Split(token, ".")
	if len(pToken) != 3 {
		return JWT{}
	}
	return JWT{
		header:    pToken[0],
		payload:   pToken[1],
		signature: pToken[2],
	}
}

// 验证token是否签名有效
// 有效返回true，无效则返回false
func verifyJWT(jwt JWT, key *rsa.PublicKey) bool {
	hashed := sha256.Sum256([]byte(jwt.header + "." + jwt.payload))
	sign, err := base64.RawURLEncoding.DecodeString(jwt.signature)
	if err != nil {
		return false
	}
	return rsa.VerifyPKCS1v15(key, crypto.SHA256, hashed[:], sign) == nil
}

// 验证token是否过期。true代表已过期
func verifyExpires(exp int64) bool {
	return exp < time.Now().Unix()
}

// ----- TraceId -----

func (p *Preprocess) addTraceId(req *http.Request, rw http.ResponseWriter) {
	id := uuid()
	req.Header.Set("TraceId", id)
	rw.Header().Add("TraceId", id)
}

/*
生成16位随机id。前8位为当前时间戳（ms）转化为36进制，后8位是随机字符
*/
func uuid() string {
	currentTime := time.Now().UnixMilli()
	randomStr := strconv.FormatInt(int64(rand.Int()), 36)
	return strconv.FormatInt(currentTime, 36) + randomStr[0:8]
}

// 重定向到特定的后端服务
func (p *Preprocess) redirect(req *http.Request, rw http.ResponseWriter) bool {
	key := ""
	for _, cookie := range req.Cookies() {
		if strings.HasPrefix(cookie.Name, p.mark) {
			key = cookie.Name
			break
		}
	}
	if key != "" {
		id := strings.TrimPrefix(key, p.mark)
		rw.Header().Set("Location", fmt.Sprintf("/%s", id+req.RequestURI))
		rw.WriteHeader(http.StatusPermanentRedirect)
		return true
	}
	return false
}
