package main

import (
	"bytes"
	"encoding/json"
	"fmt"
	"io"
	"net/http"
	"os"
	"os/exec"
	"time"
)

const vpsAPIUrl = "http://46.247.42.87:8080/update-ip"
const secretToken = "super-secret-token-123"

func getPublicIP() string {
	resp, err := http.Get("https://api.ipify.org?format=text")
	if err != nil {
		return ""
	}
	defer resp.Body.Close()
	ip, _ := io.ReadAll(resp.Body)
	return string(ip)
}

func sendIPToVPS(ip string) {
	data, _ := json.Marshal(map[string]string{"ip": ip})
	req, _ := http.NewRequest("POST", vpsAPIUrl, bytes.NewBuffer(data))
	req.Header.Set("Authorization", secretToken)
	req.Header.Set("Content-Type", "application/json")

	client := &http.Client{Timeout: 10 * time.Second}
	resp, err := client.Do(req)
	if err == nil {
		defer resp.Body.Close()
		fmt.Println("IP успешно отправлен на VPS:", ip)
	}
}

// Эта функция будет работать в фоне
func updateIPLoop() {
	var currentIP string
	for {
		ip := getPublicIP()
		if ip != "" && ip != currentIP {
			sendIPToVPS(ip)
			currentIP = ip
		}
		time.Sleep(5 * time.Minute)
	}
}

// Эта функция запускает само VPN-ядро
func startXray() {
	fmt.Println("Запуск VPN-ядра (Xray)...")
	// Запускаем xray.exe и передаем ему файл настроек
	cmd := exec.Command("xray.exe", "-c", "config.json")
	cmd.Stdout = os.Stdout
	cmd.Stderr = os.Stderr
	err := cmd.Run()
	if err != nil {
		fmt.Println("Xray остановлен или произошла ошибка:", err)
	}
}

func main() {
	fmt.Println("VPN Агент запущен...")

	// Запускаем отслеживание IP параллельно
	go updateIPLoop()

	// Запускаем VPN-приемник
	startXray()
}
