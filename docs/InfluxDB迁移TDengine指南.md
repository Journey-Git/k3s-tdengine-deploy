# InfluxDB 迁移 TDengine 完整指南

## 一、架构对比

| 维度 | InfluxDB | TDengine |
|------|----------|----------|
| 数据模型 | Database + Measurement + Point | Database + STable + Sub Table |
| 标签(Tag) | 索引字段 | TAGS（分区维度） |
| 字段(Field) | 数据值 | Column（数据列） |
| 时间戳 | 纳秒精度 | TIMESTAMP（可配置 ns/us/ms） |
| 写入方式 | HTTP API / Line Protocol | REST API / Line Protocol / JDBC |
| 查询语言 | InfluxQL / Flux | SQL（类 MySQL） |

---

## 二、taosAdapter 数据迁移

### 2.1 taosAdapter 简介

taosAdapter 是 TDengine 的 RESTful API 适配服务，提供：
- **REST API**：标准 SQL 查询/写入（端口 6041）
- **InfluxDB Line Protocol**：兼容 InfluxDB 写入格式
- **OpenTSDB**：JSON/Telnet 协议兼容
- **WebSocket**：长连接支持

文档地址：
- [taosAdapter 官方文档](https://docs.tdengine.com/taosadapter/)
- [REST API 文档](https://docs.tdengine.com/connector/rest-api/)
- [InfluxDB Line Protocol](https://docs.tdengine.com/connector/influxdb-line/)

### 2.2 迁移前准备

```bash
# 1. 确认 taosAdapter 服务正常
kubectl get svc -n ecloud | grep tdengine
# tdengine-nodeport   NodePort   10.43.x.x   <none>   6041:30441/TCP,6030:30603/TCP,6060:30660/TCP

# 2. 测试 REST API
curl -u root:taosdata http://192.168.31.222:30441/rest/sql -d "show databases"

# 3. 测试 InfluxDB Line Protocol
curl -i -X POST \
  http://192.168.31.222:30441/influxdb/v1/write?db=product_basic \
  -u root:taosdata \
  --data-binary "fitness_result,item_code=1001,student_id=12345 attempts=3,score_value=85.5 1705312200000000000"
```

### 2.3 数据迁移方案

#### 方案 A：InfluxDB Line Protocol 直接写入（推荐）

**适用场景**：实时双写、增量迁移

```python
# influxdb_to_tdengine.py
import requests
import json
from influxdb_client import InfluxDBClient

# InfluxDB 源配置
influx_client = InfluxDBClient(
    url="http://influxdb:8086",
    token="your-token",
    org="your-org"
)

# TDengine 目标配置
taos_url = "http://192.168.31.222:30441"
taos_auth = ("root", "taosdata")

def migrate_batch(measurement, start_time, end_time):
    """批量迁移一批数据"""
    query = f'''
    from(bucket: "product_basic")
      |> range(start: {start_time}, stop: {end_time})
      |> filter(fn: (r) => r._measurement == "{measurement}")
    '''
    
    tables = influx_client.query_api().query(query)
    
    lines = []
    for table in tables:
        for record in table.records:
            # InfluxDB Line Protocol 格式
            tags = ",".join([f"{k}={v}" for k, v in record.values.items() 
                            if k.startswith("_") is False and k not in ["result", "table", "_value", "_time", "_field", "_measurement"]])
            field = record.get_field()
            value = record.get_value()
            timestamp = int(record.get_time().timestamp() * 1e9)  # 纳秒
            
            line = f"{measurement},{tags} {field}={value} {timestamp}"
            lines.append(line)
    
    # 批量写入 TDengine
    data = "\n".join(lines)
    resp = requests.post(
        f"{taos_url}/influxdb/v1/write?db=product_basic",
        auth=taos_auth,
        data=data
    )
    return resp.status_code == 204

# 执行迁移
migrate_batch("fitness_result", "2024-01-01T00:00:00Z", "2024-01-02T00:00:00Z")
```

#### 方案 B：CSV 导出 + SQL 导入

**适用场景**：全量迁移、历史数据归档

```bash
# 1. InfluxDB 导出 CSV
influx query '
  from(bucket: "product_basic")
    |> range(start: -365d)
    |> filter(fn: (r) => r._measurement == "fitness_result")
' --raw > /tmp/fitness_result.csv

# 2. 转换并导入 TDengine（使用 taosdump 或自定义脚本）
python csv_to_tdengine.py --input /tmp/fitness_result.csv --db product_basic
```

#### 方案 C：Java 程序双写

**适用场景**：平滑过渡，验证数据一致性

```java
// 写入时同时写入 InfluxDB 和 TDengine
@Service
public class DataWriteService {
    
    @Autowired
    private InfluxDBClient influxClient;
    
    @Autowired
    private TDengineRestClient tdengineClient;
    
    public void writeFitnessResult(FitnessResult result) {
        // 1. 写入 InfluxDB（现有逻辑）
        influxClient.writePoint(result.toInfluxPoint());
        
        // 2. 写入 TDengine（新增逻辑）
        tdengineClient.writeLineProtocol(result.toLineProtocol());
    }
}
```

---

## 三、建表规则

### 3.1 概念映射

| InfluxDB | TDengine | 说明 |
|----------|----------|------|
| Database | Database | 直接对应，命名用下划线 |
| Measurement | Super Table (STable) | 超级表定义 schema |
| Point | Sub Table | 子表按 TAGS 组合创建 |
| Tag | TAGS | 索引维度，用于分区 |
| Field | Column | 数据列，随时间变化 |
| Timestamp | TIMESTAMP | 主键，必须存在 |

### 3.2 命名规范

| 项目 | 规则 | 示例 |
|------|------|------|
| 数据库名 | 下划线分隔 | `product_basic`（原 `product-basic`） |
| 超级表名 | 小写下划线 | `fitness_result` |
| 子表名 | `t_{tag1}_{tag2}` | `t_1001_12345` |
| 列名 | 小写下划线 | `item_code`, `student_id` |

### 3.3 建表 SQL

```sql
-- 1. 创建数据库
CREATE DATABASE IF NOT EXISTS product_basic
  KEEP 365              -- 数据保留 365 天
  VGROUPS 4             -- 4 个 vgroup，单节点建议 2-4
  PRECISION 'ns';       -- 时间精度：纳秒（与 InfluxDB 一致）

-- 2. 创建超级表（STable）
CREATE STABLE IF NOT EXISTS product_basic.fitness_result (
    ts TIMESTAMP,           -- 时间戳，主键，必须第一列
    attempts DOUBLE,        -- 尝试次数（数值型）
    score_text BINARY(64),  -- 成绩文本（字符串）
    score_value DOUBLE      -- 成绩数值（数值型）
) TAGS (
    item_code BINARY(64),   -- 项目编码（维度标签）
    student_id BINARY(64)  -- 学生 ID（维度标签）
);

-- 3. 创建子表（可选，显式命名便于管理）
CREATE TABLE IF NOT EXISTS product_basic.t_1001_12345
  USING product_basic.fitness_result
  TAGS ('1001', '12345');

-- 4. 插入数据（子表自动创建）
INSERT INTO product_basic.t_1001_12345
  VALUES ('2024-01-15 08:30:00.000000000', 3.0, '优秀', 85.5);

-- 或使用 USING 语法（自动创建子表）
INSERT INTO product_basic.fitness_result
  USING product_basic.fitness_result
  TAGS ('1001', '12345')
  VALUES ('2024-01-15 08:30:00.000000000', 3.0, '优秀', 85.5);
```

### 3.4 子表命名规则

| 方式 | 子表名 | 说明 |
|------|--------|------|
| 显式命名 | `t_1001_12345` | 应用层指定，可读可管理 |
| 自动哈希 | `t_18273645` | TDengine 内部哈希，固定但不可读 |

**推荐显式命名**，规则：`t_{item_code}_{student_id}`

```java
public String getSubTableName(String itemCode, String studentId) {
    // 注意：确保名称合法（无特殊字符，长度限制）
    return "t_" + itemCode + "_" + studentId;
}
```

### 3.5 数据类型映射

| InfluxDB 类型 | TDengine 类型 | 说明 |
|--------------|--------------|------|
| float | DOUBLE | 浮点数 |
| integer | BIGINT | 整数 |
| string | BINARY(n) | 字符串，需指定长度 |
| boolean | BOOL | 布尔值 |
| timestamp | TIMESTAMP | 时间戳 |

---

## 四、Java CRUD 操作

### 4.1 依赖引入

```xml
<!-- pom.xml -->
<dependencies>
    <!-- TDengine JDBC 驱动 -->
    <dependency>
        <groupId>com.taosdata.jdbc</groupId>
        <artifactId>taos-jdbcdriver</artifactId>
        <version>3.4.0</version>
    </dependency>
    
    <!-- 或 REST 客户端 -->
    <dependency>
        <groupId>com.squareup.okhttp3</groupId>
        <artifactId>okhttp</artifactId>
        <version>4.12.0</version>
    </dependency>
</dependencies>
```

### 4.2 JDBC 连接配置

```yaml
# application.yml
spring:
  datasource:
    # JDBC 原生连接（taosd 端口 6030）
    tdengine:
      driver-class-name: com.taosdata.jdbc.TSDBDriver
      url: jdbc:TAOS://192.168.31.222:30603/product_basic?timezone=UTC
      username: root
      password: taosdata
    
    # REST 连接（taosAdapter 端口 6041）
    tdengine-rest:
      driver-class-name: com.taosdata.jdbc.rs.RestfulDriver
      url: jdbc:TAOS-RS://192.168.31.222:30441/product_basic?timezone=UTC
      username: root
      password: taosdata
```

### 4.3 数据库操作类

```java
@Component
public class TDengineFitnessDao {
    
    @Autowired
    @Qualifier("tdengineRestDataSource")
    private DataSource dataSource;
    
    // ==================== 插入 ====================
    
    /**
     * 单条插入（显式子表名）
     */
    public void insert(FitnessResult result) throws SQLException {
        String sql = "INSERT INTO ? USING fitness_result TAGS (?, ?) VALUES (?, ?, ?, ?)";
        
        try (Connection conn = dataSource.getConnection();
             PreparedStatement pstmt = conn.prepareStatement(sql)) {
            
            String subTable = "t_" + result.getItemCode() + "_" + result.getStudentId();
            
            pstmt.setString(1, subTable);
            pstmt.setString(2, result.getItemCode());
            pstmt.setString(3, result.getStudentId());
            pstmt.setTimestamp(4, Timestamp.from(result.getTs()));
            pstmt.setDouble(5, result.getAttempts());
            pstmt.setString(6, result.getScoreText());
            pstmt.setDouble(7, result.getScoreValue());
            
            pstmt.executeUpdate();
        }
    }
    
    /**
     * 批量插入（高效）
     */
    public void batchInsert(List<FitnessResult> results) throws SQLException {
        String sql = "INSERT INTO fitness_result (ts, attempts, score_text, score_value, item_code, student_id) " +
                     "VALUES (?, ?, ?, ?, ?, ?)";
        
        try (Connection conn = dataSource.getConnection();
             PreparedStatement pstmt = conn.prepareStatement(sql)) {
            
            conn.setAutoCommit(false);
            
            for (int i = 0; i < results.size(); i++) {
                FitnessResult r = results.get(i);
                pstmt.setTimestamp(1, Timestamp.from(r.getTs()));
                pstmt.setDouble(2, r.getAttempts());
                pstmt.setString(3, r.getScoreText());
                pstmt.setDouble(4, r.getScoreValue());
                pstmt.setString(5, r.getItemCode());
                pstmt.setString(6, r.getStudentId());
                pstmt.addBatch();
                
                if (i % 1000 == 0) {
                    pstmt.executeBatch();
                    conn.commit();
                }
            }
            
            pstmt.executeBatch();
            conn.commit();
        }
    }
    
    // ==================== 查询 ====================
    
    /**
     * 按学生查询最新成绩
     */
    public List<FitnessResult> queryByStudent(String studentId, String itemCode, 
                                               Instant start, Instant end) throws SQLException {
        String sql = "SELECT ts, attempts, score_text, score_value " +
                     "FROM fitness_result " +
                     "WHERE student_id = ? AND item_code = ? " +
                     "AND ts >= ? AND ts <= ? " +
                     "ORDER BY ts DESC";
        
        List<FitnessResult> list = new ArrayList<>();
        
        try (Connection conn = dataSource.getConnection();
             PreparedStatement pstmt = conn.prepareStatement(sql)) {
            
            pstmt.setString(1, studentId);
            pstmt.setString(2, itemCode);
            pstmt.setTimestamp(3, Timestamp.from(start));
            pstmt.setTimestamp(4, Timestamp.from(end));
            
            try (ResultSet rs = pstmt.executeQuery()) {
                while (rs.next()) {
                    list.add(mapResultSet(rs));
                }
            }
        }
        
        return list;
    }
    
    /**
     * 聚合查询：平均分
     */
    public double queryAverageScore(String itemCode, Instant start, Instant end) throws SQLException {
        String sql = "SELECT AVG(score_value) as avg_score " +
                     "FROM fitness_result " +
                     "WHERE item_code = ? AND ts >= ? AND ts <= ?";
        
        try (Connection conn = dataSource.getConnection();
             PreparedStatement pstmt = conn.prepareStatement(sql)) {
            
            pstmt.setString(1, itemCode);
            pstmt.setTimestamp(2, Timestamp.from(start));
            pstmt.setTimestamp(3, Timestamp.from(end));
            
            try (ResultSet rs = pstmt.executeQuery()) {
                if (rs.next()) {
                    return rs.getDouble("avg_score");
                }
            }
        }
        
        return 0.0;
    }
    
    /**
     * 超级表查询（跨子表聚合）
     */
    public List<Map<String, Object>> queryTopStudents(String itemCode, int limit) throws SQLException {
        String sql = "SELECT student_id, MAX(score_value) as max_score, COUNT(*) as count " +
                     "FROM fitness_result " +
                     "WHERE item_code = ? " +
                     "GROUP BY student_id " +
                     "ORDER BY max_score DESC " +
                     "LIMIT ?";
        
        List<Map<String, Object>> list = new ArrayList<>();
        
        try (Connection conn = dataSource.getConnection();
             PreparedStatement pstmt = conn.prepareStatement(sql)) {
            
            pstmt.setString(1, itemCode);
            pstmt.setInt(2, limit);
            
            try (ResultSet rs = pstmt.executeQuery()) {
                while (rs.next()) {
                    Map<String, Object> map = new HashMap<>();
                    map.put("studentId", rs.getString("student_id"));
                    map.put("maxScore", rs.getDouble("max_score"));
                    map.put("count", rs.getLong("count"));
                    list.add(map);
                }
            }
        }
        
        return list;
    }
    
    // ==================== 删除 ====================
    
    /**
     * 按时间范围删除（注意：TDengine 删除是标记删除，非物理删除）
     */
    public void deleteByTimeRange(Instant start, Instant end) throws SQLException {
        String sql = "DELETE FROM fitness_result WHERE ts >= ? AND ts <= ?";
        
        try (Connection conn = dataSource.getConnection();
             PreparedStatement pstmt = conn.prepareStatement(sql)) {
            
            pstmt.setTimestamp(1, Timestamp.from(start));
            pstmt.setTimestamp(2, Timestamp.from(end));
            pstmt.executeUpdate();
        }
    }
    
    // ==================== 辅助方法 ====================
    
    private FitnessResult mapResultSet(ResultSet rs) throws SQLException {
        FitnessResult result = new FitnessResult();
        result.setTs(rs.getTimestamp("ts").toInstant());
        result.setAttempts(rs.getDouble("attempts"));
        result.setScoreText(rs.getString("score_text"));
        result.setScoreValue(rs.getDouble("score_value"));
        return result;
    }
}
```

### 4.4 REST API 客户端

```java
@Component
public class TDengineRestClient {
    
    private final OkHttpClient client = new OkHttpClient();
    private final String baseUrl = "http://192.168.31.222:30441";
    private final String auth = Credentials.basic("root", "taosdata");
    
    /**
     * 执行 SQL
     */
    public String executeSql(String db, String sql) throws IOException {
        String url = baseUrl + "/rest/sql/" + db;
        
        RequestBody body = RequestBody.create(sql, MediaType.parse("text/plain"));
        Request request = new Request.Builder()
            .url(url)
            .header("Authorization", auth)
            .post(body)
            .build();
        
        try (Response response = client.newCall(request).execute()) {
            return response.body().string();
        }
    }
    
    /**
     * InfluxDB Line Protocol 写入
     */
    public void writeLineProtocol(String db, String lineProtocol) throws IOException {
        String url = baseUrl + "/influxdb/v1/write?db=" + db;
        
        RequestBody body = RequestBody.create(lineProtocol, MediaType.parse("text/plain"));
        Request request = new Request.Builder()
            .url(url)
            .header("Authorization", auth)
            .post(body)
            .build();
        
        try (Response response = client.newCall(request).execute()) {
            if (!response.isSuccessful()) {
                throw new IOException("Write failed: " + response.body().string());
            }
        }
    }
}
```

---

## 五、注意事项

### 5.1 时区处理

| 场景 | 处理方式 |
|------|---------|
| TDengine 服务端 | UTC（已配置） |
| JDBC URL | 添加 `timezone=UTC` |
| Java 应用 | 使用 `Instant` 或 `ZonedDateTime` |
| 显示给前端 | 应用层转换为本地时区 |

```java
// 写入时：使用 UTC 时间戳
Instant now = Instant.now();  // 2024-01-15T08:30:00Z

// 查询后：转换为北京时间显示
ZonedDateTime beijingTime = result.getTs().atZone(ZoneId.of("Asia/Shanghai"));
```

### 5.2 批量写入优化

| 参数 | 建议值 | 说明 |
|------|--------|------|
| 批次大小 | 1000-10000 条 | 根据网络延迟调整 |
| 提交频率 | 每秒 1-2 次 | 避免频繁 commit |
| 多线程 | 4-8 线程 | 根据 CPU 核心数 |

```java
// 配置连接池参数
HikariConfig config = new HikariConfig();
config.setMaximumPoolSize(10);
config.setMinimumIdle(5);
config.addDataSourceProperty("batchErrorIgnore", "true");  // 忽略批次中单条错误
```

### 5.3 查询优化

| 优化点 | 说明 |
|--------|------|
| 时间范围过滤 | 必须带 `ts` 范围，避免全表扫描 |
| TAG 过滤 | `WHERE item_code = '1001'` 高效（TAG 有索引） |
| 列过滤 | 避免 `SELECT *`，只查需要的列 |
| 聚合查询 | 利用超级表跨子表聚合，无需 JOIN |
| 时间窗口 | 使用 `INTERVAL(1h)` 做降采样 |

```sql
-- 高效查询示例
SELECT _irowts, AVG(score_value) as avg_score
FROM fitness_result
WHERE item_code = '1001'
  AND ts >= '2024-01-01 00:00:00'
  AND ts <= '2024-01-31 23:59:59'
INTERVAL(1d)  -- 按天聚合
FILL(PREV);   -- 缺失值填充
```

### 5.4 数据一致性

| 阶段 | 策略 |
|------|------|
| 双写过渡期 | 同时写入 InfluxDB + TDengine，读从 InfluxDB |
| 验证期 | 对比查询结果，确认 TDengine 数据准确 |
| 切换期 | 读切换到 TDengine，保留 InfluxDB 写入 |
| 停写期 | 停止 InfluxDB 写入，只保留 TDengine |

### 5.5 常见问题

| 问题 | 原因 | 解决 |
|------|------|------|
| `Table does not exist` | 子表未创建 | 使用 `USING` 语法自动建表 |
| `Invalid timestamp format` | 时间格式不匹配 | 使用 `Timestamp` 对象或标准格式 |
| `Database not exist` | 数据库未创建 | 先执行 `CREATE DATABASE` |
| `Tag value too long` | BINARY 长度不足 | 增大 `BINARY(n)` 定义 |
| 查询慢 | 缺少时间范围 | 必须带 `ts >= ? AND ts <= ?` |

---

## 六、迁移检查清单

- [ ] 创建数据库和超级表
- [ ] 验证 taosAdapter 服务可访问
- [ ] 测试单条写入
- [ ] 批量导入历史数据
- [ ] Java 应用双写验证
- [ ] 查询结果对比（InfluxDB vs TDengine）
- [ ] 性能测试（写入 TPS、查询延迟）
- [ ] 切换读流量到 TDengine
- [ ] 停止 InfluxDB 写入
- [ ] 监控和告警配置
