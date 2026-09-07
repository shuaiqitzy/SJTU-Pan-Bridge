# SJTU Pan Bridge

用 Bash、`curl` 和 `jq` 在命令行中上传或下载上海交通大学云盘（`pan.sjtu.edu.cn`）文件，无需安装或运行 WebDAV 服务。

> [!IMPORTANT]
> 本项目调用的是云盘网页使用的接口，并非学校承诺长期兼容的公开 API。云盘升级后，脚本可能需要同步调整。请先用不重要的小文件测试。

## 功能

- 上传一个文件，并支持覆盖、自动改名或询问冲突处理策略
- 将一个本地目录打包、分片后批量上传
- 下载一个文件，支持 HTTP 断点续传
- 自动寻找一组 `*.tar.part-000`、`*.tar.part-001` 文件，下载、校验并可选解压
- 路径中的空格、中文等字符会按路径段进行 URL 编码

## 依赖

脚本面向 Bash，依赖以下命令：

- `bash`
- `curl`
- `jq`
- `tar`、`split`、`sort`（目录打包或恢复时使用）

Ubuntu / Debian：

```bash
sudo apt-get update
sudo apt-get install -y curl jq tar coreutils
```

macOS（系统已有 `curl`、`tar` 和 `split`）：

```bash
brew install jq
```

下载仓库后赋予执行权限：

```bash
git clone https://github.com/shuaiqitzy/SJTU-Pan-Bridge.git
cd SJTU-Pan-Bridge
chmod +x scripts/*.sh
```

## 获取 UserToken

1. 在自己的浏览器中登录 [上海交通大学云盘](https://pan.sjtu.edu.cn/)。
2. 打开浏览器开发者工具（通常为 `F12`）。
3. 在“应用程序（Application）→ 存储（Storage）→ Cookie”中选择 `https://pan.sjtu.edu.cn`。
4. 找到名为 `UserToken` 的 Cookie，复制它的值。

脚本在需要时会显示 `UserToken:`。粘贴后按回车即可；终端不会回显字符，这是密码式输入的正常现象。

也可以在当前终端临时设置环境变量：

```bash
read -rsp 'UserToken: ' TBOX_USER_TOKEN; echo
export TBOX_USER_TOKEN
```

完成后清除：

```bash
unset TBOX_USER_TOKEN
```

不要把真实 UserToken 写进脚本、README、Shell 启动文件、Git 提交、截图或公开日志。它等同于账号访问凭据。若怀疑泄露，请立即退出相关会话，并按学校账号与云盘提供的安全方式撤销或更新凭据。

## 快速开始

以下示例假设当前目录是仓库根目录，且云盘中的目标文件夹已经存在。远端路径是云盘个人空间内的相对路径，不是网页地址，也不要以 `/` 开头。

### 上传单个文件

```bash
./scripts/upload_file.sh \
  ./example/report.pdf \
  'DataSet/project-a/report.pdf'
```

目标文件已存在时，默认覆盖。也可以让云盘自动重命名：

```bash
TBOX_CONFLICT_STRATEGY=rename ./scripts/upload_file.sh \
  ./example/report.pdf \
  'DataSet/project-a/report.pdf'
```

`TBOX_CONFLICT_STRATEGY` 可取 `overwrite`、`rename` 或 `ask`。

### 打包并上传一个目录

```bash
./scripts/upload_directory.sh \
  ./example/images \
  'DataSet/project-a' \
  images
```

脚本会临时生成并上传：

```text
images.tar.part-000
images.tar.part-001
...
```

每片默认不超过 `3900m`，可通过环境变量修改：

```bash
TBOX_PART_SIZE=2g ./scripts/upload_directory.sh \
  ./example/images \
  'DataSet/project-a' \
  images
```

打包内容保留顶层目录名。例如上传 `./example/images`，解压后会得到 `images/`。上传成功后，本地临时分片会自动清理；云盘中的分片不会删除。

临时目录中需要有大致相当于原目录体积的可用空间。可用 `TMPDIR=/容量充足的临时目录` 改变暂存位置。当前上传接口不支持从一个未完成分片的中间继续传输；任务中断后再次执行，会重新打包并按冲突策略重新上传各分片。

### 下载单个文件

```bash
./scripts/download_file.sh \
  'DataSet/project-a/report.pdf' \
  ./downloads/report.pdf
```

如果本地目标文件已经存在，`curl --continue-at -` 会尝试从已有大小继续下载。若云盘端同名文件已经被替换，请先把旧的本地文件移走，再重新下载，以免拼接新旧版本。断点续传能力取决于服务端是否接受 Range 请求；若服务端拒绝，请删除不完整的本地文件后重试。

### 下载一组分片但暂不解压

```bash
./scripts/download_archive.sh \
  'DataSet/project-a' \
  images \
  ./downloads/images-parts
```

第二个参数是归档名，不含 `.tar.part-000` 后缀。

### 下载、检查并解压

```bash
./scripts/download_archive.sh \
  'DataSet/project-a' \
  images \
  ./downloads/images-parts \
  --extract ./restored
```

脚本会：

1. 分页读取远端目录，只选择 `images.tar.part-NNN`；
2. 检查分片是否从 `000` 开始连续编号；
3. 逐片下载，并支持单个分片断点续传；
4. 用 `tar -tf` 验证完整归档；
5. 验证通过后流式解压到目标目录。

不会自动删除下载的分片。确认文件数量和内容正确后，可自行删除对应的下载目录。

如果已经手动下载了全部分片，也可以直接合并或流式解压：

```bash
# 先合并，会额外占用一份归档空间
cat images.tar.part-* > images.tar
tar -tf images.tar
tar -xf images.tar -C ./restored

# 或直接流式检查、解压，不生成合并文件
cat images.tar.part-* | tar -tf - >/dev/null
cat images.tar.part-* | tar -C ./restored -xf -
```

只有 `tar -tf` 成功才表示分片至少构成了可读取的完整 tar 归档。重要数据还应比较文件数量、大小或 SHA-256 校验值。

## 在长时间运行的服务器任务中使用

建议在 `tmux` 中传输大型数据：

```bash
tmux new -s pan-transfer
```

在会话中执行上传或下载命令。按 `Ctrl+B`，再按 `D` 可暂时离开；之后恢复：

```bash
tmux attach -t pan-transfer
```

## 代理导致的 `curl: (7)`

如果服务器显示正在连接 `127.0.0.1:7890`、`127.0.0.1:7897` 等地址并报 `Connection refused`，通常是从另一台机器继承了代理环境变量，而服务器本机没有代理程序。

查看代理变量：

```bash
env | grep -iE '^(http|https|all|no)_proxy='
```

只对当前终端取消代理：

```bash
unset http_proxy https_proxy all_proxy HTTP_PROXY HTTPS_PROXY ALL_PROXY
```

测试直连：

```bash
curl -4 -I --connect-timeout 15 https://pan.sjtu.edu.cn/
```

如果所在网络必须使用代理，应设置为服务器实际能够访问的代理地址，而不是盲目取消。不要使用 `-k` 跳过 TLS 证书校验。

## 常见问题

### `Error: jq is required`

系统缺少 `jq`。按“依赖”一节安装即可。

### 输入 UserToken 后立即退出，状态码为 7

这通常不是 UserToken 错误，而是网络连接失败。先按上一节检查代理、防火墙、DNS 和服务器是否能访问 `pan.sjtu.edu.cn`。

### 只有 `part-000`，是否正常？

可能正常。若整个 tar 小于设定分片大小，就只有一片。请运行：

```bash
tar -tf archive.tar.part-000 >/dev/null
echo $?
```

退出码为 `0` 才说明它是可完整读取的 tar；出现 `Unexpected EOF` 等错误通常表示上传或下载不完整。

### 可以直接把网页地址当远端路径吗？

不可以。例如网页中显示 `personalSpace?path=DataSet`，脚本参数应写成 `DataSet/文件名`。

### 远端目录不存在怎么办？

当前示例脚本不会递归创建云盘目录。请先在云盘网页中创建目标目录，再上传文件。

## 脚本说明

```text
scripts/
├── upload_file.sh       # 上传单文件
├── upload_directory.sh  # 目录打包、分片并批量上传
├── download_file.sh     # 下载单文件并支持续传
└── download_archive.sh  # 查询、下载分片并可选检查和解压
```

这些脚本只处理个人空间，且仅实现本仓库示例所需的最小功能。它们不是官方客户端，也不提供 WebDAV 挂载、共享空间管理或完整的云盘文件管理能力。

## 许可证

本项目采用 [GNU GPL v2](./LICENSE) 许可证。

## 致谢与参考

本项目的接口理解和实现参考了采用 GPL-2.0 许可证的开源项目 [1357310795/TboxWebdav](https://github.com/1357310795/TboxWebdav)。TboxWebdav 对接上海交通大学新云盘（腾讯 SMH）API，并提供 WebDAV 访问能力。本仓库没有捆绑或替代其可执行程序；如需完整 WebDAV 功能，请优先查看原项目及其许可证。
