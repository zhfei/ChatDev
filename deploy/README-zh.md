# 个人 VPS 一键部署

适用：文档所列的杭州 VPS（120.26.22.130，2 核 / 2 GiB，预计 x86_64，部署脚本会核对架构）。运行一个容器：同一镜像包含 Python 后端、编译后的前端页面、Nginx 和轻量进程管理器 Supervisor。Supervisor 负责启动两个进程、退出时清理进程组，并在子进程异常退出后重启。复用应用的本地 SQLite，不增加数据库、Redis 或管理面板。模型调用外部 API，先每次运行一个轻量工作流；本地模型、Blender 等重型任务不在默认部署范围。

## 第一次准备

1. 在服务器控制台确认 Docker 可用，安装 Docker Compose v2 插件。验证 `docker info`、`docker compose version`，Compose 需要支持 `up --wait`。确认磁盘有足够空间容纳镜像包与解压后的镜像（当前发布包约 621 MiB，镜像约 1 GiB，建议至少预留 4 GiB）。不要直接在这台 2 GiB VPS 上构建 Python 依赖。
2. 准备 SSH 登录账号和模型 API Key。默认使用百炼 OpenAI 兼容地址；模型名称需要在应用工作流内设置成百炼实际支持的模型，不会自动将示例中的 OpenAI 模型替换成百炼模型。
3. 防火墙仅需允许你的 SSH 登录；应用绑定 VPS 的 127.0.0.1:8080，无需开放 8080、5173 或 6400 公网端口。

## 生成发布包（开发机或 CI，需 Docker）

在仓库根目录运行，版本号每次使用不同值：

```bash
bash deploy/build.sh single-v3 /tmp/chatdev-release-single-v3
```

构建目标固定为 linux/amd64。Mac ARM 开发机需要 Docker 支持跨架构构建。发布包包含一个镜像和部署脚本，不包含 API Key。最终运行时只有一个 `chatdev` 镜像、一个 `app` 服务，内部后端端口 6400 不发布。构建阶段的 Node/Python 构建器不会作为额外容器部署。不需要 Docker Hub / GHCR 账号；通过 SSH 上传，绕过 VPS 拉取国外基础镜像的问题。构建机仍需能访问 Docker 镜像源、PyPI、npm 和 Debian 软件源。

如果构建机处于企业代理环境且需要自定义信任链，可运行 `BUILD_CA_BUNDLE=/path/to/trusted-ca-bundle.crt bash deploy/build.sh single-v3 /tmp/chatdev-release-single-v3`。该证书仅通过 BuildKit 临时 secret 用于依赖下载，不会关闭 TLS 校验或写入最终镜像。普通开发机无需设置。

## 上传与一键启动

将 `USER` 替换成实际 SSH 用户。服务器目录归该用户所有，该用户须有 Docker 权限：

```bash
ssh USER@120.26.22.130 'mkdir -p ~/chatdev'
scp /tmp/chatdev-release-single-v3/* USER@120.26.22.130:~/chatdev/
ssh -t USER@120.26.22.130 'cd ~/chatdev && bash deploy.sh'
```

首次启动会询问 API 地址与密钥（输入不回显），保存在服务器本地权限为 600 的 `.env`；后续部署复用配置。脚本加载镜像、启动容器、等待后端健康并验证经 Nginx 转发的工作流列表。失败会以非零状态退出，不会清除数据或自动覆盖密钥。

在自己的电脑另开一个终端，保持下面命令运行：

```bash
ssh -N -L 8080:127.0.0.1:8080 USER@120.26.22.130
```

浏览器打开 `http://localhost:8080`。这是你电脑的 SSH 隧道入口。首次验收：打开工作流列表、选择兼容当前供应商的模型、发起一次简短请求并确认结果。无密钥时无法验证真实模型调用。

## 更新、数据与日常使用

- 更新：用新的版本号重新构建、上传到同一个目录，再执行 `bash deploy.sh`。会短暂中断正在运行的任务；部署前等任务完成。
- 查看状态：在服务器 `~/chatdev` 下执行 `docker compose --env-file version.env ps`。
- 查看日志：`docker compose --env-file version.env logs --tail=100`。
- 停止：`docker compose --env-file version.env stop`。重新启动：`docker compose --env-file version.env up -d --wait`。
- 回退：上一版镜像尚在本机时，执行 `docker compose --env-file previous-version.env up -d --wait`；随后将 `previous-version.env` 复制为 `version.env`。镜像回退不恢复数据；升级若涉及数据格式变化，先恢复兼容备份。
- 数据、上传/生成文件、工作流和日志使用 Docker 命名卷，普通更新和重启保留。不要执行 `down -v` 或删除这些卷。工作流卷首次从镜像初始化，后续保留你的修改，新版内置示例不会自动覆盖它。
- 备份：先停止容器，在阿里云控制台创建磁盘快照，完成后启动；重要结果另外下载到自己的电脑。快照费用以控制台为准。
- 容器日志已轮转；应用文件日志和生成文件仍会增长，定期下载/清理不需要的结果，检查 `df -h`、`docker system df`。不要自动清除回退所需的镜像。

Compose 设置整个容器内存限额 1200 MiB、CPU 限额 1.5 核，预留系统资源；实际限额依赖宿主机的 cgroups 支持，需要在 VPS 上确认生效。这不是实测容量承诺。出现 OOM 时先减少任务规模，必要时升级内存。自定义 Python 执行默认关闭，确有需要再理解项目的执行限制后开启。远程部署不支持项目限定为“仅本地”的工具安装接口，常规工作流与文件接口不受此限制。

## 实施边界

当前只使用附件提供的 VPS 规格，没有登录服务器，也没有验证该机的 Compose、现有业务、SSH、剩余磁盘或模型出口。这里的“一键”指一次性基础准备完成后，一条部署命令完成版本发布；不会替你猜测 SSH 凭据、修改已有服务或开放公网。若以后希望直接通过公网域名访问，再添加 HTTPS 和访问认证即可。

## 当前构建验证

已在开发云环境构建单镜像，并通过单容器健康检查、首页与前端路由、工作流 API、WebSocket 握手、后端进程异常恢复和容器重建后数据保留验证。未在目标 VPS 上执行，真实模型请求仍需使用你的供应商密钥验收。
