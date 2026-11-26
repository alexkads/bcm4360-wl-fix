---
name: reinstalar-correcao-wifi
description: Roteiro para reinstalar, do zero, a correção do Wi-Fi Broadcom BCM4360 (driver wl) deste repositório num Fedora recém-formatado (MacBook Pro 2013–2015), e para recompilar o wl corrigido quando um kernel novo ou uma atualização do RPM Fusion quebrar o remendo. Use quando a máquina for formatada ou reinstalada, quando o Fedora novo ficar sem Wi-Fi, ao montar outra máquina com BCM4360, quando o Wi-Fi voltar a travar sob download, quando `wlctl get vhtmode` falhar ou `modinfo -n wl` não apontar para updates/, ou quando o `wl-ioctl-build` disser que o remendo não aplica mais.
---

# Reinstalar a correção do Wi-Fi (BCM4360 / wl)

O que este repositório corrige: o núcleo fechado do driver `wl` trava a recepção sob download rápido no 802.11ac. A correção desliga o 802.11ac (`vhtmode=0`) por um remendo que religa o ioctl privado do driver (`ndo_siocdevprivate`, kernel ≥ 5.15).

- Diagnóstico e provas: `README.md` e `docs/investigation.md`.
- Estado e critérios de aceite: issue #1 (https://github.com/alexkads/bcm4360-wl-fix/issues/1).

**Verificado em:** MacBookPro11,2, Fedora 45, kernel 7.3.5, `akmod-wl` 6.30.223.271-64, em 26/11/2026. Se o Fedora ou o RPM Fusion mudarem, confira cada passo antes de dar por certo.

## Antes de formatar

Não há nada a guardar: tudo sai deste repositório. Anote só o que não está nele:

- **O vigia da máquina** (`vigia-do-wifi`) não está no repositório. Depois de formatar, use o `contrib/wl-watchdog` (`./install.sh --with-watchdog`), que tem a mesma lógica.
- **O `wifi-sem-aspm` não precisa voltar:** o ASPM foi descartado como causa (`docs/investigation.md`, hipótese 1).

## Passo 0: rede provisória (o Fedora novo não tem driver para o BCM4360)

Nenhum driver do kernel suporta o BCM4360. O `wl` vem do RPM Fusion, e baixá-lo exige rede. Use uma destas:

- **Celular por USB (tethering):** os drivers `rndis_host` (Android) e `cdc_ncm` (iPhone, Android novo) já vêm no kernel. Ligue o "Ancoragem USB" no celular, e o NetworkManager conecta sozinho.
- **Adaptador Ethernet USB 3** (RTL8153 → `r8152`, AX88179 → `ax88179_178a`) ou **Thunderbolt → Ethernet** da Apple (`tg3`). Também já vêm no kernel.

Confira que há rede antes de continuar:

```bash
nmcli device                      # um dispositivo "ethernet" ou "gsm" conectado
ping -c 3 mirrors.rpmfusion.org
```

## Passo 1: atualizar o sistema e reiniciar

```bash
sudo dnf upgrade --refresh -y
sudo reboot
```

Por quê: o `kernel-devel` precisa ser da **mesma versão do kernel em uso**. Se o `dnf upgrade` trouxer um kernel novo e você seguir sem reiniciar, o módulo é compilado para o kernel errado.

## Passo 2: RPM Fusion e o driver de fábrica

```bash
sudo dnf install -y \
  "https://mirrors.rpmfusion.org/free/fedora/rpmfusion-free-release-$(rpm -E %fedora).noarch.rpm" \
  "https://mirrors.rpmfusion.org/nonfree/fedora/rpmfusion-nonfree-release-$(rpm -E %fedora).noarch.rpm"
sudo dnf install -y akmod-wl "kernel-devel-$(uname -r)"
sudo akmods --force --kernels "$(uname -r)"
sudo reboot
```

Depois do reinício, o driver de fábrica tem de funcionar:

```bash
lsmod | grep '^wl '                                # wl carregado
nmcli device wifi list                             # redes aparecendo
nmcli device wifi connect "<SSID>" --ask           # conectar (pede a senha)
```

Se o `wl` não carregar, confira se o `modinfo wl` acha o módulo e se o `akmods` terminou (`journalctl -u akmods`). **Não continue com o driver de fábrica quebrado:** a correção é compilada por cima dele.

Com o Wi-Fi funcionando, o cabo ou o celular já podem sair.

## Passo 3: ferramentas de compilação e o repositório

```bash
sudo dnf install -y gcc make patch rpm cpio git-core
git clone https://github.com/alexkads/bcm4360-wl-fix.git
cd bcm4360-wl-fix
sudo ./install.sh --with-watchdog
sudo reboot
```

O que o `install.sh` faz:

- confere as dependências: `akmod-wl`, o `kernel-devel` do kernel atual e as ferramentas;
- instala o remendo em `/usr/local/share/wl-ioctl/` e os scripts em `/usr/local/sbin/`;
- instala o gancho de kernel novo (`/etc/kernel/install.d/96-wl-ioctl.install`) e os serviços;
- compila o `wlctl`, compila o `wl` corrigido para o kernel atual e ativa os serviços.

Ele não mexe nos pacotes do RPM Fusion.

## Passo 4: conferir

```bash
sudo tests/check.sh        # cada item com ✅/❌; só sai com código 0 se tudo passar
```

O mínimo que precisa estar ✅:

- `modinfo -n wl` aponta para `/lib/modules/<kver>/updates/wl.ko`, e não para `extra/wl/wl.ko.xz`;
- o `wl` carregado aceita o ioctl;
- `vhtmode=0`;
- `wl-disable-vht` ativo e rodado neste boot;
- o gancho de kernel instalado;
- o roteador responde.

Avisos ⚠️ de kernels antigos sem `updates/wl.ko` são normais: o `wl-disable-vht.service` compila no primeiro boot deles.

Se o `wlctl` disser `Operation not supported (is the patched wl module loaded?)`, quem está carregado é o módulo de fábrica. Rode `sudo wl-ioctl-build && sudo tests/experiments/wl-reload.sh`.

## Passo 5 (recomendado): provar com estresse

O mesmo teste que reproduzia a queda em ~2 min antes da correção:

```bash
# em OUTRA máquina da mesma rede (servidor). NÃO use --idle-timeout: ele fecha a porta entre testes.
iperf3 -s --rcv-timeout 15000

# na máquina corrigida (cliente)
sudo dnf install -y iperf3
nohup tests/stall-test.sh -s <IP-do-servidor> -t 1200 > /dev/null 2>&1 &   # 20 min de download, 8 fluxos
tail -f results/stall-*/summary.txt
```

- **Critério:** `result: 0 stall(s)` em 20 min, a ~140 Mbit/s.
- **Referência:** sem a correção, foram 6 quedas em ~15 min a ~240 Mbit/s.
- **Prova A/B, opcional:** `sudo tests/experiments/vht.sh on` → `stall-test.sh` (as quedas devem voltar em minutos) → `sudo tests/experiments/vht.sh off`.
- Depois do teste, desinstale o `iperf3` nas duas máquinas e apague `results/`.

## Replicar a investigação

Todos os testes de 26/11/2026 estão em `tests/`; ver a tabela no `README.md`, seção "Reproducing the tests":

- `sudo tests/trace-wl.sh start` → provocar a queda → `sudo tests/trace-wl.sh stop`. O log mostra, segundo a segundo, `wl_isr`, `wl_dpc` e `wl_sendup`. Na queda, o `wl_sendup` vai a 0 enquanto as interrupções continuam.
- `tests/experiments/aspm.sh`, `passivemode.sh` e `vht.sh` são as hipóteses 1, 6 e 7 do `docs/investigation.md`. Cada uma deve ser seguida de um `stall-test.sh`.
- `tests/experiments/wl-reload.sh` recarrega o driver com reset do barramento PCI, a única recarga que destrava o chip.

## Como a compilação funciona (para refazer à mão)

O `sbin/wl-ioctl-build [kver]` faz, nesta ordem:

1. **Pega o SRPM** que o `akmod-wl` deixou em `/usr/src/akmods/wl-kmod.latest`, a mesma fonte que o akmods usa.
2. **Extrai** com `rpm2cpio | cpio -idm` e abre o `hybrid-v35_64-nodebug-pcoem-*.tar.gz` (x86_64).
3. **Aplica os remendos do RPM Fusion** na ordem do `wl-kmod.spec` (`Patch0`, `Patch1`, …, eram 38 na -64), com `patch -p1`.
4. **Aplica `patches/0001-wl-add-ndo_siocdevprivate.patch`**, primeiro em `--dry-run`, para falhar com mensagem clara se não encaixar.
5. **Compila** com `make -C /usr/src/kernels/<kver> M=<dir> modules` (2 jobs, `nice 10`).
6. **Instala** em `/lib/modules/<kver>/updates/wl.ko`, roda `restorecon` (SELinux) e `depmod -a <kver>`. O `updates/` tem prioridade sobre o `extra/` do akmods no `modprobe`.

O mesmo à mão, para depurar:

```bash
W=$(mktemp -d /var/tmp/wl-manual.XXXX); cd "$W"
rpm2cpio "$(readlink -f /usr/src/akmods/wl-kmod.latest)" | cpio -idm --quiet
mkdir src && tar -C src -xzf hybrid-v35_64-nodebug-pcoem-*.tar.gz
awk '/^Patch[0-9]+:/{n=$1; gsub(/[^0-9]/,"",n); print n, $2}' wl-kmod.spec | sort -n |
  while read -r _ p; do patch -d src -p1 < "$p"; done
patch -d src -p1 < /usr/local/share/wl-ioctl/0001-wl-add-ndo_siocdevprivate.patch
make -C "/usr/src/kernels/$(uname -r)" M="$W/src" modules
modinfo src/wl.ko | grep vermagic      # tem de bater com uname -r
```

## Quando o remendo não aplica mais

O `wl-ioctl-build` avisa `our patch no longer applies` quando o RPM Fusion muda o trecho em volta do `ndo_do_ioctl` em `src/wl/sys/wl_linux.c`. Nesse caso:

```bash
tests/regenerate-patch.sh --build     # refaz o remendo contra o SRPM instalado e prova que compila
git diff patches/                     # revisar
sudo ./install.sh && sudo tests/check.sh
```

Depois abra um PR neste repositório citando `rpm -q akmod-wl`.

O script aplica sempre a mesma edição: `wl_siocdevprivate()` antes do `wl_netdev_ops`, e `.ndo_siocdevprivate` nos dois `net_device_ops`. Se ele disser que o RPM Fusion **já** tem o `ndo_siocdevprivate`, o nosso remendo deixou de ser necessário. Basta o `wl-disable-vht`, e o `wl-ioctl-build` pode ser removido do fluxo.

## Kernel novo

- O gancho `/etc/kernel/install.d/96-wl-ioctl.install` compila o `wl` corrigido quando o kernel é instalado. O log fica em `/var/log/wl-ioctl.log`.
- Se o `kernel-devel` chegou depois, o `wl-disable-vht.service` compila no primeiro boot, e o NetworkManager espera.
- **Antes de reiniciar num kernel novo**, confira:

  ```bash
  K=<versão-nova>
  ls -la /lib/modules/$K/updates/wl.ko           # o corrigido
  modinfo -k $K -n wl                            # tem de apontar para updates/
  ```

  Se faltar, rode `sudo wl-ioctl-build $K`. Sem nenhum `wl` (nem o do akmods), a máquina volta sem rede. Nesse caso, volte ao passo 0 (celular ou cabo) e escolha o kernel anterior no GRUB.

## Armadilhas já encontradas

- **SELinux:**
  - o systemd não executa script de `/var/tmp` (`status=203/EXEC`) nem abre ali o `StandardOutput=file:` (`209/STDOUT`);
  - o `insmod` recusa módulo que não esteja em `/lib/modules` (rótulo `modules_object_t`).

  Os scripts do repositório já respeitam isso. Se for testar à mão, use `bash script` e o redirecionamento dentro do `bash -c`.
- **Recarregar só o módulo não destrava o chip:** é preciso o reset do barramento PCI (`echo 1 > /sys/bus/pci/devices/<pci>/reset`), e depois reiniciar o `wpa_supplicant` e o NetworkManager. O `wl-watchdog` faz isso.
- **`vhtmode` só muda com o driver em down:** `wlctl cmd 3; wlctl set vhtmode 0; wlctl cmd 2`. Com o driver em up, a resposta é `Invalid argument`.
- **Ajustes de A-MPDU** (`ampdu_rx`, `ampdu_rx_factor`, `ampdu_ba_wsize`, `amsdu`) respondem `Operation not supported` nesta versão. Funcionam `vhtmode`, `nmode`, `mimo_bw_cap` e `stbc_rx`.
- **Secure Boot:** o Mac não tem (`mokutil --sb-state` responde "doesn't support Secure Boot"). Numa máquina com Secure Boot ligado, o `wl.ko` precisa ser assinado com a chave do akmods antes do `depmod`:
  `sudo /usr/src/kernels/$K/scripts/sign-file sha256 /etc/pki/akmods/private/private_key.priv /etc/pki/akmods/certs/public_key.der /lib/modules/$K/updates/wl.ko`
- **`wlctl` sem root** dá `Operation not permitted`: o driver exige `CAP_NET_ADMIN`.
- **kprobe** (para rastrear de novo, ver `docs/investigation.md` §3): só funciona nas funções da casca (`wl_isr`, `wl_dpc`, `wl_sendup`…). As do núcleo fechado são `notrace`. Os kprobes de módulo se perdem quando o módulo é recarregado.

## Desfazer

```bash
cd bcm4360-wl-fix && sudo ./uninstall.sh && sudo reboot
```

Volta o `wl` de fábrica do RPM Fusion, com o 802.11ac ligado e sujeito às quedas.
