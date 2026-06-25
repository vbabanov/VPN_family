package main

import (
	"embed"
	"encoding/json"
	"io/ioutil"
	"net/http"
	"os"
	"os/exec"
	"path/filepath"
	"strings"
	"syscall"
	"time"

	"github.com/getlantern/systray"

	"golang.org/x/sys/windows/registry"
)

//go:embed xray.exe config_vps.json template_home.json
var embeddedFiles embed.FS

var (
	xrayCmd   *exec.Cmd
	currentIP string
)

func main() {
	systray.Run(onReady, onExit)
}

func onReady() {
	systray.SetTitle("Family VPN")
	systray.SetTooltip("Family VPN: Выберите сервер")

	// Меню выбора
	mVps := systray.AddMenuItemCheckbox("Облачный Сервер (Германия)", "Стабильный канал", true)
	mHome := systray.AddMenuItemCheckbox("Домашний ПК (Астана)", "Личный канал", false)
	systray.AddSeparator()
	mQuit := systray.AddMenuItem("Выйти", "Закрыть")

	// По умолчанию запускаем VPS
	go switchServer("VPS")

	// Цикл обработки кликов
	go func() {
		for {
			select {
			case <-mVps.ClickedCh:
				mVps.Check()
				mHome.Uncheck()
				switchServer("VPS")
			case <-mHome.ClickedCh:
				mHome.Check()
				mVps.Uncheck()
				switchServer("HOME")
			case <-mQuit.ClickedCh:
				systray.Quit()
			}
		}
	}()
}

// switchServer останавливает старый Xray и запускает новый с нужным конфигом
func switchServer(serverType string) {
	stopXray()

	tempDir := os.TempDir()
	xrayPath := filepath.Join(tempDir, "xray_family.exe")
	configPath := filepath.Join(tempDir, "config_active.json")

	// Извлекаем xray.exe если его еще нет
	if _, err := os.Stat(xrayPath); os.IsNotExist(err) {
		data, _ := embeddedFiles.ReadFile("xray.exe")
		ioutil.WriteFile(xrayPath, data, 0755)
	}

	var configContent string
	if serverType == "VPS" {
		data, _ := embeddedFiles.ReadFile("config_vps.json")
		configContent = string(data)
	} else {
		// Для ДОМА: сначала получаем IP через твой API
		homeIP := fetchHomeIP()
		data, _ := embeddedFiles.ReadFile("template_home.json")
		// Заменяем заглушку на реальный IP
		configContent = strings.ReplaceAll(string(data), "{{HOME_IP}}", homeIP)
	}

	ioutil.WriteFile(configPath, []byte(configContent), 0644)

	// Запуск
	xrayCmd = exec.Command(xrayPath, "-c", configPath)
	xrayCmd.SysProcAttr = &syscall.SysProcAttr{HideWindow: true}
	xrayCmd.Start()

	setSystemProxy(true)
}

func fetchHomeIP() string {
	client := http.Client{Timeout: 5 * time.Second}
	resp, err := client.Get("http://46.247.42.87:8080/get-ip")
	if err != nil {
		return "127.0.0.1" // Ошибка
	}
	defer resp.Body.Close()
	var result map[string]string
	json.NewDecoder(resp.Body).Decode(&result)
	return result["home_ip"]
}

func stopXray() {
	if xrayCmd != nil && xrayCmd.Process != nil {
		xrayCmd.Process.Kill()
	}
}

func setSystemProxy(enable bool) {
	k, _ := registry.OpenKey(registry.CURRENT_USER, `Software\Microsoft\Windows\CurrentVersion\Internet Settings`, registry.SET_VALUE)
	defer k.Close()
	if enable {
		k.SetStringValue("ProxyServer", "socks=127.0.0.1:10808")
		k.SetDWordValue("ProxyEnable", 1)
	} else {
		k.SetDWordValue("ProxyEnable", 0)
	}
}

func onExit() {
	setSystemProxy(false)
	stopXray()
}
