FROM mcr.microsoft.com/dotnet/sdk:10.0 AS build
WORKDIR /source

COPY global.json ./
COPY src/ToolCabinetApi/ToolCabinetApi.csproj src/ToolCabinetApi/
RUN dotnet restore src/ToolCabinetApi/ToolCabinetApi.csproj

COPY src/ToolCabinetApi/ src/ToolCabinetApi/
RUN dotnet publish src/ToolCabinetApi/ToolCabinetApi.csproj \
    --configuration Release --no-restore --output /app/publish \
    -p:UseAppHost=false

FROM mcr.microsoft.com/dotnet/aspnet:10.0 AS runtime
WORKDIR /app
ENV ASPNETCORE_HTTP_PORTS=8080
EXPOSE 8080
COPY --from=build /app/publish/ ./
USER $APP_UID
ENTRYPOINT ["dotnet", "ToolCabinetApi.dll"]
