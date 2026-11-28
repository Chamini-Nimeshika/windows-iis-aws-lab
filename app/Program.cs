var builder = WebApplication.CreateBuilder(args);

builder.Services.AddRazorPages();
builder.Services.AddHealthChecks();          // added

var app = builder.Build();

if (!app.Environment.IsDevelopment())
{
    app.UseExceptionHandler("/Error");
    app.UseHsts();
}

app.UseHttpsRedirection();
app.UseRouting();
app.UseAuthorization();

app.MapStaticAssets();
app.MapRazorPages().WithStaticAssets();

app.MapHealthChecks("/health");              // added: returns "Healthy"
app.MapGet("/version", (IWebHostEnvironment env) =>   // added: shows the deployed build
{
    var f = Path.Combine(env.ContentRootPath, "version.txt");
    return File.Exists(f) ? File.ReadAllText(f) : "dev";
});

app.Run();