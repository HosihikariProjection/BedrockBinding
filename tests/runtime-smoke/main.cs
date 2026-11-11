using System;
using System.IO;
using System.Text;
using Microsoft.Extensions.Logging;
using Hosihikari;
using Hosihikari.Bindings.Bedrock.Interop;

// Loads the generated BindingShim inside a real BDS process and exercises the
// name-resolved surface: static string accessors, a constructed packet, an instance
// method, and a by-value TextPacket returned from a factory that also takes a string.
// HashedString's constructors and Core::Random::Random are not in the 1.26.60.6 runtime
// data snapshot (v26.60.6-server.1), so the 26.51 checks that build those values do not
// apply here.
public sealed class BedrockSmokePlugin : IPlugin
{
    private IPluginContext _context = null!;

    public void OnLoad(IPluginContext context) => _context = context;

    public PluginHookResult OnEnable()
    {
        System.IO.Directory.CreateDirectory(_context.DataDirectory);
        var resultPath = System.IO.Path.Combine(_context.DataDirectory, "bedrock-smoke.txt");
        var log = new StringBuilder();

        try
        {
            NativeMethods.Load(System.IO.Path.Combine(
                _context.PackageDirectory,
                "Hosihikari.Bindings.Bedrock.Shim.dll"));
            log.AppendLine("load=ok");

            var prefix = Block.BLOCK_DESCRIPTION_PREFIX();
            log.AppendLine($"block.prefix={prefix}");
            if (prefix != "tile.")
            {
                throw new InvalidOperationException($"unexpected block prefix: {prefix}");
            }

            var enchants = ItemStackBase.TAG_ENCHANTS();
            log.AppendLine($"item.enchants={enchants}");
            if (enchants != "ench")
            {
                throw new InvalidOperationException($"unexpected enchant tag: {enchants}");
            }

            using (var packet = TextPacket.Create())
            {
                log.AppendLine($"textpacket.isvalid={packet.isValid()}");
                if (!packet.isValid())
                {
                    throw new InvalidOperationException("the constructed packet is not valid.");
                }
            }

            // Returns a TextPacket by value while taking a std::string argument, so this
            // exercises the shim-owned string, the by-value result, and Dispose of the owned
            // wrapper in one call.
            using (var packet = TextPacketPayload.createSystemMessage("projection-smoke"))
            {
                log.AppendLine($"systemmessage.isvalid={packet.isValid()}");
                if (!packet.isValid())
                {
                    throw new InvalidOperationException("the created system message packet is not valid.");
                }
            }

            // BlockPos::center is not in this build's runtime data, so the shim cannot resolve
            // it. A wrapper around the resulting null handle would look alive and fail on the
            // next call; the projection maps it to null instead.
            using (var pos = new BlockPos(IntPtr.Zero))
            {
                var center = pos.center();
                log.AppendLine($"blockpos.center.isnull={center == null}");
                if (center != null)
                {
                    throw new InvalidOperationException("a member without a symbol returned a non-null wrapper.");
                }
            }

            log.AppendLine("result=OK");
        }
        catch (Exception exception)
        {
            log.AppendLine("result=FAIL");
            log.AppendLine(exception.ToString());
            _context.Logger.LogInformation("bedrock smoke failed: {Error}", exception);
        }

        System.IO.File.WriteAllText(resultPath, log.ToString());
        return PluginHookResult.Allow();
    }

    public PluginHookResult OnDisable() => PluginHookResult.Allow();

    public void OnUnload()
    {
    }
}
