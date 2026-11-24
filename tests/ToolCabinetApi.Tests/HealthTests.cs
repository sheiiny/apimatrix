using System.Net;
using System.Text.Json;
using Microsoft.AspNetCore.Mvc.Testing;
using Xunit;

namespace ToolCabinetApi.Tests;

public class HealthTests : IClassFixture<WebApplicationFactory<Program>>
{
    private readonly WebApplicationFactory<Program> _factory;

    public HealthTests(WebApplicationFactory<Program> factory) => _factory = factory;

    [Fact]
    public async Task GetHealth_ReturnsOkWithExpectedJson()
    {
        using var client = _factory.CreateClient(new WebApplicationFactoryClientOptions
        {
            AllowAutoRedirect = false
        });

        using var response = await client.GetAsync("/api/v1/health");

        Assert.Equal(HttpStatusCode.OK, response.StatusCode);
        Assert.Equal("application/json", response.Content.Headers.ContentType?.MediaType);

        using var json = JsonDocument.Parse(await response.Content.ReadAsStringAsync());
        Assert.Equal(JsonValueKind.Object, json.RootElement.ValueKind);
        var property = Assert.Single(json.RootElement.EnumerateObject());
        Assert.Equal("status", property.Name);
        Assert.Equal("ok", property.Value.GetString());
    }
}
