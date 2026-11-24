var builder = WebApplication.CreateBuilder(args);
var app = builder.Build();

app.MapGet("/api/v1/health", () => Results.Ok(new { status = "ok" }));

app.Run();

// WebApplicationFactory использует эту точку входа в интеграционных тестах.
public partial class Program { }
